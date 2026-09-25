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
from app.services.representative_songs import representative_songs_for_artist
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
    with patch(f"{_SERVICE}.search_artist_detailed", new=mb):
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
