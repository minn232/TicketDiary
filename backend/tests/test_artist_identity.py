import uuid
from unittest.mock import AsyncMock, patch

import pytest
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from app.core.database import AsyncSessionLocal
from app.main import app
from app.models.artist_identity import ArtistIdentityChange, ConcertArtistLink
from app.models.artist_normalization import ArtistAlias, CanonicalArtist
from app.services.artist_identity import resolve_concert_artist
from app.services.representative_songs import (
    candidate_top_songs,
    candidate_top_songs_for,
    representative_songs_for_artist,
)
from app.services.setlist import search_with_artist_fallbacks
from conftest import _get_token
from test_admin import _admin_headers, _admin_settings
from test_pre_setlists import _create_concert
from test_representative_songs import _create_ticket, _lastfm, _setlistfm_not_found

_SERVICE = "app.services.artist_identity"


# 헬퍼

async def _canonical(name: str, *, mbid: str | None = None, alias: str | None = None, itunes: str | None = None):
    async with AsyncSessionLocal() as db:
        canonical = CanonicalArtist(mbid=mbid, canonical_name=name, itunes_artist_id=itunes)
        db.add(canonical)
        await db.flush()
        if alias:
            db.add(ArtistAlias(canonical_artist_id=canonical.id, alias_text=alias, source="musicbrainz"))
        await db.commit()
        return canonical.id


async def _concert_and_ticket(artist: str) -> tuple[uuid.UUID, str, str]:
    concert_id = await _create_concert(f"PF_ID_{uuid.uuid4().hex[:6]}", artist=artist)
    token = await _get_token()
    ticket_id = await _create_ticket(concert_id, token)
    return uuid.UUID(concert_id), ticket_id, token


async def _post_change(ticket_id: str, token: str, body: dict):
    with _setlistfm_not_found(), _lastfm("", []):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            return await ac.post(
                f"/api/v1/tickets/{ticket_id}/artist-identity",
                json=body,
                headers={"Authorization": f"Bearer {token}"},
            )


async def _resolve(concert_id, artist):
    async with AsyncSessionLocal() as db:
        canonical, no_artist = await resolve_concert_artist(db, concert_id, artist)
        return (canonical.id if canonical else None), no_artist


async def _changes(concert_id) -> list[ArtistIdentityChange]:
    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(ArtistIdentityChange)
            .where(ArtistIdentityChange.concert_id == concert_id)
            .order_by(ArtistIdentityChange.created_at)
        )
        return list(result.scalars().all())


# 후보

@pytest.mark.asyncio
async def test_candidates_merge_db_namesakes_and_musicbrainz():
    artist = f"동명가수{uuid.uuid4().hex[:6]}"
    current_id = await _canonical(f"{artist}-현재", mbid=f"mbid-cur-{artist}", alias=artist)
    other_id = await _canonical(artist, mbid=f"mbid-other-{artist}")
    concert_id, ticket_id, token = await _concert_and_ticket(artist)

    mb = AsyncMock(return_value=[
        {"mbid": f"mbid-other-{artist}", "name": artist, "country": "KR", "type": "Person",
         "disambiguation": "trot singer", "begin_year": "1970"},
        {"mbid": f"mbid-new-{artist}", "name": artist, "country": "JP", "type": "Group",
         "disambiguation": None, "begin_year": "2015"},
    ])
    songs = AsyncMock(side_effect=lambda pairs: [[f"{mbid}-곡"] for mbid, _ in pairs])
    with patch(f"{_SERVICE}.search_artist_detailed", new=mb), patch(
        "app.services.representative_songs.candidate_top_songs_for", new=songs
    ):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.get(
                f"/api/v1/tickets/{ticket_id}/artist-identity/candidates",
                params={"artist": artist},
                headers={"Authorization": f"Bearer {token}"},
            )

    assert res.status_code == 200
    data = res.json()
    assert data["current"]["canonical_id"] == str(current_id)
    by_mbid = {c["mbid"]: c for c in data["candidates"]}
    assert by_mbid[f"mbid-cur-{artist}"]["is_current"] is True
    # DB에 있는 동명이인에 MusicBrainz 설명을 붙이고, 같은 mbid는 한 번만
    assert by_mbid[f"mbid-other-{artist}"]["canonical_id"] == str(other_id)
    assert by_mbid[f"mbid-other-{artist}"]["disambiguation"] == "trot singer"
    assert by_mbid[f"mbid-new-{artist}"]["canonical_id"] is None
    assert len(data["candidates"]) == 3
    # 후보마다 알아볼 곡을 붙임
    assert by_mbid[f"mbid-new-{artist}"]["top_songs"] == [f"mbid-new-{artist}-곡"]


# 후보 곡 - Last.fm(mbid) 인기순이 먼저, 없으면 Apple Music 링크로 iTunes 곡 목록

_SONGS = "app.services.representative_songs"


@pytest.mark.asyncio
async def test_candidate_top_songs_prefers_lastfm_by_mbid():
    mbid = f"mbid-lf-{uuid.uuid4().hex[:6]}"
    lastfm = AsyncMock(return_value=("", [("Smooth", 900), ("Smooth (Live)", 800), ("가져가", 700), ("셋째", 600)]))
    apple = AsyncMock()
    with patch(f"{_SONGS}.fetch_top_tracks", new=lastfm), patch(f"{_SONGS}.fetch_apple_music_artist_id", new=apple):
        songs = await candidate_top_songs(mbid)

    assert songs == ["Smooth", "가져가"]
    lastfm.assert_awaited_once_with(mbid=mbid, limit=10, strict_mbid=True)
    apple.assert_not_awaited()


@pytest.mark.asyncio
async def test_candidate_top_songs_falls_back_to_itunes_via_apple_link():
    mbid = f"mbid-it-{uuid.uuid4().hex[:6]}"
    catalog = AsyncMock(return_value=[("첫곡", "First"), ("둘째곡", "Second"), ("셋째곡", "Third")])
    with patch(f"{_SONGS}.fetch_top_tracks", new=AsyncMock(return_value=("", []))), patch(
        f"{_SONGS}.fetch_apple_music_artist_id", new=AsyncMock(return_value="123")
    ), patch(f"{_SONGS}.fetch_itunes_artist_song_titles", new=catalog):
        songs = await candidate_top_songs(mbid)

    assert songs == ["첫곡", "둘째곡"]
    catalog.assert_awaited_once_with("123")


@pytest.mark.asyncio
async def test_candidate_top_songs_uses_known_itunes_id_without_musicbrainz():
    apple = AsyncMock()
    with patch(f"{_SONGS}.fetch_apple_music_artist_id", new=apple), patch(
        f"{_SONGS}.fetch_itunes_artist_song_titles", new=AsyncMock(return_value=[("곡", "Song")])
    ):
        songs = await candidate_top_songs(None, f"it-{uuid.uuid4().hex[:6]}")

    assert songs == ["곡"]
    apple.assert_not_awaited()


# strict_mbid - 곡의 아티스트 mbid가 요청한 mbid와 다르면 버림(Last.fm이 다른 동명이인 페이지를 준 것)
@pytest.mark.asyncio
async def test_fetch_top_tracks_strict_mbid_drops_other_artist_tracks():
    from unittest.mock import MagicMock

    from app.services.lastfm import fetch_top_tracks

    payload = {"toptracks": {"@attr": {"artist": "Lany"}, "track": [
        {"name": "ILYSB", "listeners": "9", "artist": {"mbid": "mbid-other"}},
    ]}}
    response = MagicMock(status_code=200, json=MagicMock(return_value=payload))
    client = MagicMock()
    client.__aenter__ = AsyncMock(return_value=client)
    client.__aexit__ = AsyncMock(return_value=None)
    client.get = AsyncMock(return_value=response)
    with patch("app.services.lastfm.httpx.AsyncClient", return_value=client), patch(
        "app.services.lastfm.settings.LASTFM_API_KEY", "test-key"
    ):
        assert await fetch_top_tracks(mbid="mbid-asked", strict_mbid=True) == ("Lany", [])
        assert await fetch_top_tracks(mbid="mbid-asked") == ("Lany", [("ILYSB", 9)])


# Last.fm이 동명이인을 한 페이지로 합쳐 다른 후보와 곡이 겹치면 그 후보는 iTunes만 씀(LANY/Lany 실측)
@pytest.mark.asyncio
async def test_candidate_top_songs_for_drops_lastfm_songs_shared_with_other_candidate():
    real, fake, other = (f"mbid-{name}-{uuid.uuid4().hex[:6]}" for name in ("real", "fake", "other"))
    lastfm_by_mbid = {
        real: [],
        fake: [("ILYSB", 9), ("Malibu Nights", 8), ("Super Far", 7)],
        other: [("Renaissance", 5), ("People Of The Night", 4)],
    }
    catalog_by_id = {"it-real": [("ILYSB", "ILYSB"), ("Malibu Nights", "Malibu Nights"), ("Super Far", "Super Far")]}
    apple_by_mbid = {real: "it-real"}

    async def lastfm(*, mbid, limit, strict_mbid):
        return "", lastfm_by_mbid[mbid]

    with patch(f"{_SONGS}.fetch_top_tracks", new=AsyncMock(side_effect=lastfm)), patch(
        f"{_SONGS}.fetch_apple_music_artist_id", new=AsyncMock(side_effect=lambda m: apple_by_mbid.get(m))
    ), patch(
        f"{_SONGS}.fetch_itunes_artist_song_titles", new=AsyncMock(side_effect=lambda i: catalog_by_id.get(i, []))
    ):
        songs = await candidate_top_songs_for([(real, None), (fake, None), (other, None)])

    assert songs == [["ILYSB", "Malibu Nights"], [], ["Renaissance", "People Of The Night"]]


# 곡 제목 하나 겹치는 건 우연일 수 있어 그대로 둠
@pytest.mark.asyncio
async def test_candidate_top_songs_for_keeps_single_title_overlap():
    a, b = (f"mbid-{name}-{uuid.uuid4().hex[:6]}" for name in ("a", "b"))
    lastfm_by_mbid = {a: [("Home", 9), ("A2", 8)], b: [("Home", 9), ("B2", 8)]}

    async def lastfm(*, mbid, limit, strict_mbid):
        return "", lastfm_by_mbid[mbid]

    with patch(f"{_SONGS}.fetch_top_tracks", new=AsyncMock(side_effect=lastfm)):
        songs = await candidate_top_songs_for([(a, None), (b, None)])

    assert songs == [["Home", "A2"], ["Home", "B2"]]


# 일본어 제목은 iTunes us 제목(영문/로마자)으로 바꾸고, 바꿔도 못 읽는 곡은 뒤로
@pytest.mark.asyncio
async def test_candidate_top_songs_romanizes_japanese_titles_via_itunes_us():
    mbid = f"mbid-jp-{uuid.uuid4().hex[:6]}"
    lastfm = AsyncMock(return_value=("", [("夜に駆ける", 900), ("アイドル", 800), ("群青", 700)]))
    catalog = AsyncMock(return_value=[("夜に駆ける", "夜に駆ける"), ("アイドル", "Idol"), ("群青", "Gunjou")])
    with patch(f"{_SONGS}.fetch_top_tracks", new=lastfm), patch(
        f"{_SONGS}.fetch_apple_music_artist_id", new=AsyncMock(return_value="555")
    ), patch(f"{_SONGS}.fetch_itunes_artist_song_titles", new=catalog):
        songs = await candidate_top_songs(mbid)

    assert songs == ["Idol", "Gunjou"]
    catalog.assert_awaited_once_with("555")


# 한글/영문 제목만 있으면 iTunes를 추가로 부르지 않음
@pytest.mark.asyncio
async def test_candidate_top_songs_skips_itunes_when_titles_readable():
    mbid = f"mbid-ko-{uuid.uuid4().hex[:6]}"
    catalog = AsyncMock()
    with patch(f"{_SONGS}.fetch_top_tracks", new=AsyncMock(return_value=("", [("Smooth", 9), ("가져가", 8)]))), patch(
        f"{_SONGS}.fetch_itunes_artist_song_titles", new=catalog
    ):
        assert await candidate_top_songs(mbid) == ["Smooth", "가져가"]
    catalog.assert_not_awaited()


# us에도 원제뿐이면(중국어권) 원제 그대로
@pytest.mark.asyncio
async def test_candidate_top_songs_keeps_original_when_no_latin_title():
    mbid = f"mbid-zh-{uuid.uuid4().hex[:6]}"
    with patch(f"{_SONGS}.fetch_top_tracks", new=AsyncMock(return_value=("", [("七里香", 9), ("晴天", 8)]))), patch(
        f"{_SONGS}.fetch_apple_music_artist_id", new=AsyncMock(return_value=None)
    ):
        assert await candidate_top_songs(mbid) == ["七里香", "晴天"]


# 변경은 이 공연에만

@pytest.mark.asyncio
async def test_change_applies_to_this_concert_only_and_is_logged():
    artist = f"공연별가수{uuid.uuid4().hex[:6]}"
    global_id = await _canonical(f"{artist}-전역", mbid=f"mbid-g-{artist}", alias=artist)
    right_id = await _canonical(f"{artist}-맞는사람", mbid=f"mbid-r-{artist}")
    concert_id, ticket_id, token = await _concert_and_ticket(artist)
    other_concert, _, _ = await _concert_and_ticket(artist)

    res = await _post_change(ticket_id, token, {"artist": artist, "canonical_id": str(right_id)})

    assert res.status_code == 200
    assert res.json()["current"]["canonical_id"] == str(right_id)
    assert await _resolve(concert_id, artist) == (right_id, False)
    assert await _resolve(other_concert, artist) == (global_id, False)  # 다른 공연은 그대로
    changes = await _changes(concert_id)
    assert len(changes) == 1
    assert changes[0].before_canonical_id == global_id
    assert changes[0].after_canonical_id == right_id
    assert changes[0].before_was_link is False
    assert changes[0].source == "user"


# 공연 정보 표시 - 연결을 바꾼 공연만 연결된 아티스트 이름으로(원본 artist_name은 그대로)
@pytest.mark.asyncio
async def test_ticket_responses_show_linked_artist_name_for_this_concert_only():
    artist = f"표시가수{uuid.uuid4().hex[:6]}"
    await _canonical(f"{artist}-전역", mbid=f"mbid-g-{artist}", alias=artist)
    right_id = await _canonical(f"{artist}-맞는사람", mbid=f"mbid-r-{artist}")
    concert_id, ticket_id, token = await _concert_and_ticket(artist)
    other_concert, other_ticket, other_token = await _concert_and_ticket(artist)

    with patch("app.api.v1.endpoints.tickets.refresh_setlists_after_identity_change", new=AsyncMock()):
        assert (await _post_change(ticket_id, token, {"artist": artist, "canonical_id": str(right_id)})).status_code == 200

    headers = {"Authorization": f"Bearer {token}"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        detail = (await ac.get(f"/api/v1/tickets/{ticket_id}", headers=headers)).json()
        listed = (await ac.get("/api/v1/tickets", headers=headers)).json()
        other = (await ac.get(f"/api/v1/tickets/{other_ticket}", headers={"Authorization": f"Bearer {other_token}"})).json()

    assert detail["concert"]["artist_name"] == [artist]
    assert detail["concert"]["artist_display_names"] == [f"{artist}-맞는사람"]
    assert next(t for t in listed if t["id"] == ticket_id)["concert"]["artist_display_names"] == [f"{artist}-맞는사람"]
    assert other["concert"]["artist_display_names"] == [artist]


@pytest.mark.asyncio
async def test_change_to_musicbrainz_candidate_creates_canonical():
    artist = f"새가수{uuid.uuid4().hex[:6]}"
    concert_id, ticket_id, token = await _concert_and_ticket(artist)
    mbid = f"mbid-mb-{artist}"

    detail = AsyncMock(return_value={"mbid": mbid, "name": f"{artist} (MB)", "country": "KR",
                                     "type": "Person", "disambiguation": None, "begin_year": None})
    with patch(f"{_SERVICE}.fetch_artist_detail", new=detail), patch(
        f"{_SERVICE}._fetch_and_store_group_relations", new=AsyncMock()
    ), patch(f"{_SERVICE}._register_wikidata_korean_alias", new=AsyncMock()), patch(
        f"{_SERVICE}._register_artist_image", new=AsyncMock()
    ):
        res = await _post_change(ticket_id, token, {"artist": artist, "mbid": mbid})

    assert res.status_code == 200
    assert res.json()["current"]["mbid"] == mbid
    async with AsyncSessionLocal() as db:
        created = (await db.execute(select(CanonicalArtist).where(CanonicalArtist.mbid == mbid))).scalar_one()
        # 전역 별칭은 안 만듦(같은 이름의 다른 공연엔 영향 없게)
        aliases = (await db.execute(
            select(ArtistAlias).where(ArtistAlias.canonical_artist_id == created.id, ArtistAlias.alias_text == artist)
        )).scalars().all()
    assert aliases == []
    assert await _resolve(concert_id, artist) == (created.id, False)


@pytest.mark.asyncio
async def test_change_to_no_artist_and_same_target_is_noop():
    artist = f"없음가수{uuid.uuid4().hex[:6]}"
    await _canonical(f"{artist}-전역", mbid=f"mbid-n-{artist}", alias=artist)
    concert_id, ticket_id, token = await _concert_and_ticket(artist)

    res = await _post_change(ticket_id, token, {"artist": artist, "no_artist": True})
    assert res.status_code == 200
    assert res.json()["no_artist"] is True
    assert await _resolve(concert_id, artist) == (None, True)

    # 같은 연결로 다시 바꾸면 기록 없이 그대로
    await _post_change(ticket_id, token, {"artist": artist, "no_artist": True})
    assert len(await _changes(concert_id)) == 1


@pytest.mark.asyncio
async def test_change_rejects_artist_not_in_concert_and_multiple_targets():
    artist = f"검증가수{uuid.uuid4().hex[:6]}"
    target = await _canonical(f"{artist}-대상")
    _, ticket_id, token = await _concert_and_ticket(artist)

    res = await _post_change(ticket_id, token, {"artist": "다른가수", "canonical_id": str(target)})
    assert res.status_code == 400
    res = await _post_change(ticket_id, token, {"artist": artist, "canonical_id": str(target), "no_artist": True})
    assert res.status_code == 400


# 관리자 기록/되돌리기

@pytest.mark.asyncio
async def test_admin_revert_latest_only_and_restores_previous():
    artist = f"되돌림가수{uuid.uuid4().hex[:6]}"
    global_id = await _canonical(f"{artist}-전역", mbid=f"mbid-rg-{artist}", alias=artist)
    first_id = await _canonical(f"{artist}-첫번째")
    second_id = await _canonical(f"{artist}-두번째")
    concert_id, ticket_id, token = await _concert_and_ticket(artist)
    await _post_change(ticket_id, token, {"artist": artist, "canonical_id": str(first_id)})
    await _post_change(ticket_id, token, {"artist": artist, "canonical_id": str(second_id)})
    first, second = await _changes(concert_id)

    async def admin(method: str, path: str):
        with _admin_settings(), _setlistfm_not_found(), _lastfm("", []):
            async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
                return await ac.request(method, f"/api/v1/admin{path}", headers=_admin_headers())

    listing = await admin("GET", "/artist-identity-changes")
    assert listing.status_code == 200
    assert {r["id"] for r in listing.json()} >= {str(first.id), str(second.id)}

    # 더 최근 변경이 있으면 안 됨
    assert (await admin("POST", f"/artist-identity-changes/{first.id}/revert")).status_code == 409

    latest = await admin("POST", f"/artist-identity-changes/{second.id}/revert")
    assert latest.status_code == 200 and latest.json()["reverted_at"] is not None
    assert await _resolve(concert_id, artist) == (first_id, False)
    assert (await admin("POST", f"/artist-identity-changes/{second.id}/revert")).status_code == 409  # 이미 되돌림

    assert (await admin("POST", f"/artist-identity-changes/{first.id}/revert")).status_code == 200
    # 처음엔 공연별 연결 없이 전역 별칭이었으므로 연결 자체가 사라짐
    assert await _resolve(concert_id, artist) == (global_id, False)
    async with AsyncSessionLocal() as db:
        links = (await db.execute(select(ConcertArtistLink).where(ConcertArtistLink.concert_id == concert_id))).all()
    assert links == []


# 대표곡/셋리 검색이 공연별 연결을 따름

@pytest.mark.asyncio
async def test_representative_songs_and_setlist_search_follow_concert_link():
    artist = f"링크가수{uuid.uuid4().hex[:6]}"
    await _canonical(f"{artist}-전역", itunes="111", alias=artist)
    right_id = await _canonical(f"{artist}-맞는사람", itunes="222")
    concert_id, ticket_id, token = await _concert_and_ticket(artist)
    await _post_change(ticket_id, token, {"artist": artist, "canonical_id": str(right_id)})

    catalog = AsyncMock(return_value=["맞는사람곡"])
    with patch("app.services.representative_songs.fetch_itunes_artist_songs", new=catalog), _lastfm("", []):
        async with AsyncSessionLocal() as db:
            songs = await representative_songs_for_artist(db, artist, 20, concert_id)
    catalog.assert_awaited_once_with("222")
    assert [s["name"] for s in songs] == ["맞는사람곡"]

    # "없음"으로 바꾸면 대표곡도, Setlist.fm 검색도 안 함
    await _post_change(ticket_id, token, {"artist": artist, "no_artist": True})
    search = AsyncMock(return_value=[{"id": "x"}])
    async with AsyncSessionLocal() as db:
        assert await representative_songs_for_artist(db, artist, 20, concert_id) == []
        assert await search_with_artist_fallbacks(db, artist, search, concert_id) == []
    search.assert_not_awaited()


# 실제 셋리가 비었을 때 아티스트별 상태 - 앱 빈 화면 문구용

async def _get_real_setlist(ticket_id: str, token: str) -> dict:
    songs = AsyncMock(side_effect=lambda mbid, itunes=None, limit=2: [f"{mbid}-대표곡"])
    with patch("app.api.v1.endpoints.tickets.check_real_setlist_on_view", new=AsyncMock()), patch(
        "app.services.representative_songs.candidate_top_songs", new=songs
    ):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.get(f"/api/v1/tickets/{ticket_id}/setlist", headers={"Authorization": f"Bearer {token}"})
    assert res.status_code == 200
    return res.json()


@pytest.mark.asyncio
async def test_real_setlist_statuses_searching_then_searched_with_top_song():
    from datetime import date, datetime, timezone

    from app.models.setlist import RealSetlist

    artist = f"상태가수{uuid.uuid4().hex[:6]}"
    await _canonical(f"{artist}-표시", mbid=f"mbid-s-{artist}", alias=artist)
    concert_id, ticket_id, token = await _concert_and_ticket(artist)

    data = await _get_real_setlist(ticket_id, token)
    assert data["artist_statuses"] == [
        {"artist": artist, "state": "searching", "name": f"{artist}-표시", "top_song": f"mbid-s-{artist}-대표곡"}
    ]

    async with AsyncSessionLocal() as db:
        db.add(RealSetlist(concert_id=concert_id, performance_date=date(2030, 6, 1), songs=[],
                           attempted_at=datetime.now(timezone.utc)))
        await db.commit()
    data = await _get_real_setlist(ticket_id, token)
    assert data["artist_statuses"][0]["state"] == "searched"


@pytest.mark.asyncio
async def test_real_setlist_statuses_unresolved_and_not_artist():
    artist = f"미확정가수{uuid.uuid4().hex[:6]}"
    await _canonical(artist, mbid=None, alias=artist)
    _, ticket_id, token = await _concert_and_ticket(artist)
    assert (await _get_real_setlist(ticket_id, token))["artist_statuses"] == [
        {"artist": artist, "state": "unresolved", "name": None, "top_song": None}
    ]

    assert (await _post_change(ticket_id, token, {"artist": artist, "no_artist": True})).status_code == 200
    assert (await _get_real_setlist(ticket_id, token))["artist_statuses"][0]["state"] == "not_artist"


@pytest.mark.asyncio
async def test_real_setlist_statuses_empty_when_solo_has_songs():
    from datetime import date

    from app.models.setlist import RealSetlist

    artist = f"곡있는가수{uuid.uuid4().hex[:6]}"
    await _canonical(artist, mbid=f"mbid-h-{artist}", alias=artist)
    concert_id, ticket_id, token = await _concert_and_ticket(artist)
    async with AsyncSessionLocal() as db:
        db.add(RealSetlist(concert_id=concert_id, performance_date=date(2030, 6, 1), songs=[{"name": "곡"}]))
        await db.commit()

    assert (await _get_real_setlist(ticket_id, token))["artist_statuses"] == []


# 페스티벌 - 다른 아티스트 곡이 채워진 행이면 attempted_at이 없어도 찾아본 것으로
@pytest.mark.asyncio
async def test_real_setlist_statuses_festival_row_with_songs_counts_as_searched():
    from datetime import date

    from app.models.setlist import RealSetlist

    a = f"페스A{uuid.uuid4().hex[:6]}"
    b = f"페스B{uuid.uuid4().hex[:6]}"
    await _canonical(b, mbid=f"mbid-b-{b}", alias=b)
    concert_id = await _create_concert(f"PF_FEST_{uuid.uuid4().hex[:6]}", artist=f"{a}, {b}")
    token = await _get_token()
    ticket_id = await _create_ticket(concert_id, token)
    async with AsyncSessionLocal() as db:
        db.add(RealSetlist(concert_id=uuid.UUID(concert_id), performance_date=date(2030, 6, 1),
                           songs=[{"name": "곡", "artist": a}]))
        await db.commit()

    statuses = (await _get_real_setlist(ticket_id, token))["artist_statuses"]
    assert [(s["artist"], s["state"]) for s in statuses] == [(b, "searched")]
