from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi import HTTPException
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from app.core.database import AsyncSessionLocal
from app.main import app
from app.models.artist_normalization import ArtistGroupMembership, CanonicalArtist
from app.models.setlist import PreSetlist
from app.services.pre_setlist import generate_pre_setlist
from app.services.representative_songs import (
    _dedupe_titles,
    fetch_itunes_artist_songs,
    _artist_candidate_cache,
    representative_songs_for_artist,
    search_itunes_artists,
    search_itunes_songs,
)
from conftest import _get_token
from test_pre_setlists import _create_concert

_SERVICE = "app.services.representative_songs"


@pytest.fixture(autouse=True)
def _clear_artist_candidate_cache():
    _artist_candidate_cache.clear()
    yield


# 헬퍼

# Setlist.fm은 항상 404(과거 셋리 없음) - 대표곡 경로만 타게 함
def _setlistfm_not_found():
    mock_response = MagicMock()
    mock_response.status_code = 404
    mock_response.json = MagicMock(return_value={})
    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = AsyncMock(return_value=mock_response)
    return patch("app.services.setlistfm.httpx.AsyncClient", return_value=mock_client)


def _lastfm(resolved_name: str, tracks: list[tuple[str, int]]):
    return patch(f"{_SERVICE}.fetch_top_tracks", new=AsyncMock(return_value=(resolved_name, tracks)))


def _tracks(count: int, top_listeners: int) -> list[tuple[str, int]]:
    return [(f"곡{i}", top_listeners - i) for i in range(count)]


async def _add_canonical(name: str, mbid: str | None = None, itunes_artist_id: str | None = None) -> None:
    async with AsyncSessionLocal() as db:
        db.add(CanonicalArtist(mbid=mbid, canonical_name=name, itunes_artist_id=itunes_artist_id))
        await db.commit()


async def _get_canonical(name: str) -> CanonicalArtist | None:
    async with AsyncSessionLocal() as db:
        result = await db.execute(select(CanonicalArtist).where(CanonicalArtist.canonical_name == name))
        return result.scalar_one_or_none()


async def _create_ticket(concert_id: str, token: str) -> str:
    with _setlistfm_not_found(), _lastfm("", []):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                "/api/v1/tickets", json={"concert_id": concert_id}, headers={"Authorization": f"Bearer {token}"}
            )
    return response.json()["id"]


# 곡 제목 정리

def test_dedupe_titles_keeps_non_latin_and_drops_alt_versions():
    titles = ["좋은날", "좋은 날", "Good Day (Live)", "マリーゴールド", "Blueming", "blueming!",
              "You just laugh (Inst.)", "좋은날 (MR)"]
    assert _dedupe_titles(titles) == ["좋은날", "マリーゴールド", "Blueming"]


# iTunes - us 스토어로 검색/순서, kr 스토어 재조회로 한글 제목

# country별로 다른 응답을 주는 iTunes 모킹
def _itunes_mock(by_country: dict[str, list[dict]]):
    async def _get(url, params=None):
        response = MagicMock()
        response.status_code = 200
        response.raise_for_status = MagicMock()
        response.json = MagicMock(return_value={"results": by_country.get(params.get("country"), [])})
        return response

    client = MagicMock()
    client.__aenter__ = AsyncMock(return_value=client)
    client.__aexit__ = AsyncMock(return_value=None)
    client.get = AsyncMock(side_effect=_get)
    return patch(f"{_SERVICE}.httpx.AsyncClient", return_value=client)


def _track(track_id: int, artist_id: int, artist: str, title: str) -> dict:
    return {"wrapperType": "track", "trackId": track_id, "artistId": artist_id, "artistName": artist,
            "trackName": title, "collectionName": "앨범", "artworkUrl100": "https://example.com/a.jpg"}


@pytest.mark.asyncio
async def test_search_itunes_songs_uses_korean_titles():
    us = [_track(1, 10, "JANNABI", "For Lovers Who Hesitate"), _track(2, 20, "Only US", "US Song")]
    kr = [_track(1, 10, "잔나비", "주저하는 연인들을 위해")]
    with _itunes_mock({"us": us, "kr": kr}):
        candidates = await search_itunes_songs("주저하는 연인들을 위해")

    # kr에 없는 곡은 us 표기 그대로
    assert [(c["artist_name"], c["track_name"]) for c in candidates] == [
        ("잔나비", "주저하는 연인들을 위해"),
        ("Only US", "US Song"),
    ]


@pytest.mark.asyncio
async def test_fetch_itunes_artist_songs_us_order_kr_titles_own_tracks_only():
    us = [
        {"wrapperType": "artist", "artistId": 10},
        _track(1, 10, "JANNABI", "For Lovers Who Hesitate"),
        _track(2, 99, "Other", "Silhouette (feat. JANNABI)"),  # 피처링으로만 참여한 남의 곡
        _track(3, 10, "JANNABI", "Summer"),
    ]
    kr = [_track(3, 10, "잔나비", "여름"), _track(1, 10, "잔나비", "주저하는 연인들을 위해")]
    with _itunes_mock({"us": us, "kr": kr}):
        assert await fetch_itunes_artist_songs("10") == ["주저하는 연인들을 위해", "여름"]


# 아티스트 이름으로 앵커 후보 검색

def _itunes_artist_search_mock(artists: list[dict], us_tracks: list[dict], kr_tracks: list[dict]):
    async def _get(url, params=None):
        response = MagicMock()
        response.status_code = 200
        response.raise_for_status = MagicMock()
        if url.endswith("/search"):
            results = artists
        else:
            results = us_tracks if params.get("country") == "us" else kr_tracks
        response.json = MagicMock(return_value={"results": results})
        return response

    client = MagicMock()
    client.__aenter__ = AsyncMock(return_value=client)
    client.__aexit__ = AsyncMock(return_value=None)
    client.get = AsyncMock(side_effect=_get)
    return patch(f"{_SERVICE}.httpx.AsyncClient", return_value=client), client


@pytest.mark.asyncio
async def test_search_itunes_artists_korean_names_exact_first_and_cached():
    artists = [
        {"artistId": 1, "artistName": "Kim Hyun Jung & Friends", "primaryGenreName": "K-Pop"},
        {"artistId": 2, "artistName": "Kim Hyun Jung", "primaryGenreName": "K-Pop"},
        {"artistId": 3, "artistName": "Kim Hyun Jung", "primaryGenreName": "Classical"},  # 곡 없음
    ]
    us = [
        _track(11, 1, "Kim Hyun Jung & Friends", "Together"),
        _track(21, 2, "Kim Hyun Jung", "Breakup"),
        _track(22, 2, "Kim Hyun Jung", "Breakup"),  # 같은 곡 중복
        _track(23, 2, "Kim Hyun Jung", "Mung (Inst.)"),
    ]
    kr = [
        _track(21, 2, "김현정", "그녀와의 이별"),
        _track(22, 2, "김현정", "그녀와의 이별"),
        _track(11, 1, "김현정과 친구들", "투게더"),
    ]
    mock, client = _itunes_artist_search_mock(artists, us, kr)
    with mock:
        candidates = await search_itunes_artists("김현정")
        again = await search_itunes_artists("김현정")

    # 이름이 정확히 같은 후보가 앞, 곡 없는 후보는 제외, 한글 이름/제목은 kr 곡 항목에서
    assert [(c["itunes_artist_id"], c["artist_name"], c["top_songs"]) for c in candidates] == [
        ("2", "김현정", ["그녀와의 이별"]),
        ("1", "김현정과 친구들", ["투게더"]),
    ]
    assert again == candidates
    assert client.get.await_count == 3  # 두 번째 검색은 캐시


@pytest.mark.asyncio
async def test_artist_candidates_rejects_artist_not_in_concert():
    concert_id = await _create_concert("PF_REP_CAND_001", artist="후보가수A")
    token = await _get_token()
    ticket_id = await _create_ticket(concert_id, token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.get(
            f"/api/v1/tickets/{ticket_id}/setlist/pre/artist-candidates",
            params={"artist": "다른가수"},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 400


# Last.fm만으로 채우는 경우 - 품질 기준(1위 청취자 50명+, 5곡+)

@pytest.mark.asyncio
async def test_lastfm_tracks_passing_quality_gate():
    await _add_canonical("대표곡가수A", mbid="mbid-rep-a")
    with _lastfm("", _tracks(6, top_listeners=80)), patch(
        f"{_SERVICE}.fetch_apple_music_artist_id", new=AsyncMock(return_value=None)
    ):
        async with AsyncSessionLocal() as db:
            songs = await representative_songs_for_artist(db, "대표곡가수A", 20)

    assert [s["name"] for s in songs] == [f"곡{i}" for i in range(6)]
    assert all(s["source"] == "representative" and s["encore"] is False for s in songs)


@pytest.mark.asyncio
async def test_lastfm_tracks_below_listener_threshold_rejected():
    # 무명 아티스트는 청취자 수십 명 이하에 잡음이 섞여 있음(실측) - 빈 채로 둠
    await _add_canonical("대표곡가수B", mbid="mbid-rep-b")
    with _lastfm("", _tracks(10, top_listeners=23)), patch(
        f"{_SERVICE}.fetch_apple_music_artist_id", new=AsyncMock(return_value=None)
    ):
        async with AsyncSessionLocal() as db:
            assert await representative_songs_for_artist(db, "대표곡가수B", 20) == []


@pytest.mark.asyncio
async def test_lastfm_tracks_too_few_rejected():
    await _add_canonical("대표곡가수C", mbid="mbid-rep-c")
    with _lastfm("", _tracks(4, top_listeners=5000)), patch(
        f"{_SERVICE}.fetch_apple_music_artist_id", new=AsyncMock(return_value=None)
    ):
        async with AsyncSessionLocal() as db:
            assert await representative_songs_for_artist(db, "대표곡가수C", 20) == []


@pytest.mark.asyncio
async def test_lastfm_name_lookup_other_script_rejected():
    # mbid 없이 이름으로 조회했는데 Last.fm이 로마자 아티스트로 인식 - 같은 사람인지 확인 불가
    with _lastfm("SEOLA", _tracks(10, top_listeners=5000)):
        async with AsyncSessionLocal() as db:
            assert await representative_songs_for_artist(db, "정규화안된대표곡가수", 20) == []


# iTunes 아티스트가 확정된 경우

@pytest.mark.asyncio
async def test_itunes_catalog_ranked_by_lastfm_listeners():
    await _add_canonical("대표곡가수D", itunes_artist_id="111")
    catalog = AsyncMock(return_value=["덜유명한곡", "제일유명한곡", "중간곡"])
    with patch(f"{_SERVICE}.fetch_itunes_artist_songs", new=catalog), _lastfm(
        "대표곡가수D", [("제일유명한곡", 900), ("중간곡", 300)]
    ):
        async with AsyncSessionLocal() as db:
            songs = await representative_songs_for_artist(db, "대표곡가수D", 20)

    catalog.assert_awaited_once_with("111")
    assert [s["name"] for s in songs] == ["제일유명한곡", "중간곡", "덜유명한곡"]


@pytest.mark.asyncio
async def test_musicbrainz_apple_link_saved_as_anchor():
    await _add_canonical("대표곡가수E", mbid="mbid-rep-e")
    with patch(f"{_SERVICE}.fetch_apple_music_artist_id", new=AsyncMock(return_value="222")), patch(
        f"{_SERVICE}.fetch_itunes_artist_songs", new=AsyncMock(return_value=["곡A"])
    ), _lastfm("", []):
        async with AsyncSessionLocal() as db:
            songs = await representative_songs_for_artist(db, "대표곡가수E", 20)

    assert [s["name"] for s in songs] == ["곡A"]
    canonical = await _get_canonical("대표곡가수E")
    assert canonical.itunes_artist_id == "222"
    assert canonical.anchor_confirmed_by == "musicbrainz"


# 자동 확정 - iTunes에 이름이 정확히 같은 후보가 1명뿐일 때만

def _candidate(itunes_artist_id: str, exact: bool) -> dict:
    return {"itunes_artist_id": itunes_artist_id, "artist_name": "이름", "genre": None,
            "top_songs": ["곡"], "artwork_url": None, "exact_match": exact}


@pytest.mark.asyncio
async def test_auto_anchor_single_exact_candidate():
    # 비슷한 이름(협업 등)은 섞여 있어도 정확히 같은 이름이 1명이면 확정, canonical이 없으면 새로 만듦
    candidates = AsyncMock(return_value=[_candidate("901", True), _candidate("902", False)])
    catalog = AsyncMock(return_value=["자동곡1", "자동곡2"])
    with patch(f"{_SERVICE}.search_itunes_artists", new=candidates), patch(
        f"{_SERVICE}.fetch_itunes_artist_songs", new=catalog
    ), _lastfm("", []):
        async with AsyncSessionLocal() as db:
            songs = await representative_songs_for_artist(db, "자동확정가수A", 20)

    catalog.assert_awaited_once_with("901")
    assert [s["name"] for s in songs] == ["자동곡1", "자동곡2"]
    canonical = await _get_canonical("자동확정가수A")
    assert canonical.itunes_artist_id == "901"
    assert canonical.anchor_confirmed_by == "auto"


@pytest.mark.asyncio
async def test_auto_anchor_skipped_when_several_exact_candidates():
    # 동명이인이 여럿이면 유저가 고르게 둠
    candidates = AsyncMock(return_value=[_candidate("911", True), _candidate("912", True)])
    catalog = AsyncMock(return_value=["곡"])
    with patch(f"{_SERVICE}.search_itunes_artists", new=candidates), patch(
        f"{_SERVICE}.fetch_itunes_artist_songs", new=catalog
    ), _lastfm("", []):
        async with AsyncSessionLocal() as db:
            assert await representative_songs_for_artist(db, "자동확정가수B", 20) == []

    catalog.assert_not_awaited()
    assert await _get_canonical("자동확정가수B") is None


@pytest.mark.asyncio
async def test_auto_anchor_failure_does_not_break_generation():
    # iTunes 제한/오류여도 예외 없이 다음 단계(Last.fm)로 넘어감
    failing = AsyncMock(side_effect=HTTPException(status_code=502, detail="iTunes 검색에 실패했습니다."))
    with patch(f"{_SERVICE}.search_itunes_artists", new=failing), _lastfm("자동확정가수C", _tracks(6, top_listeners=80)):
        async with AsyncSessionLocal() as db:
            songs = await representative_songs_for_artist(db, "자동확정가수C", 20)

    assert [s["name"] for s in songs] == [f"곡{i}" for i in range(6)]


@pytest.mark.asyncio
async def test_band_member_skips_auto_anchor_and_lastfm():
    # 밴드 멤버는 솔로 카탈로그가 없는 경우가 많아 iTunes/Last.fm 모두 동명이인이 잡힘(실사례: NELL
    # 이재경/김종완) - 유저가 고르게 둠
    async with AsyncSessionLocal() as db:
        member = CanonicalArtist(mbid="mbid-member-a", canonical_name="밴드멤버가수A")
        band = CanonicalArtist(mbid="mbid-band-a", canonical_name="어떤밴드A")
        db.add_all([member, band])
        await db.flush()
        db.add(ArtistGroupMembership(member_canonical_id=member.id, group_canonical_id=band.id))
        await db.commit()

    candidates = AsyncMock(return_value=[_candidate("921", True)])
    lastfm = AsyncMock(return_value=("", _tracks(6, top_listeners=5000)))
    with patch(f"{_SERVICE}.search_itunes_artists", new=candidates), patch(
        f"{_SERVICE}.fetch_apple_music_artist_id", new=AsyncMock(return_value=None)
    ), patch(f"{_SERVICE}.fetch_top_tracks", new=lastfm):
        async with AsyncSessionLocal() as db:
            assert await representative_songs_for_artist(db, "밴드멤버가수A", 20) == []

    candidates.assert_not_awaited()
    lastfm.assert_not_awaited()
    assert (await _get_canonical("밴드멤버가수A")).itunes_artist_id is None


@pytest.mark.asyncio
async def test_band_member_uses_user_confirmed_itunes():
    # 밴드 멤버라도 유저가 직접 고른 iTunes 아티스트는 씀
    async with AsyncSessionLocal() as db:
        member = CanonicalArtist(mbid="mbid-member-b", canonical_name="밴드멤버가수B", itunes_artist_id="941")
        band = CanonicalArtist(mbid="mbid-band-b", canonical_name="어떤밴드B")
        db.add_all([member, band])
        await db.flush()
        db.add(ArtistGroupMembership(member_canonical_id=member.id, group_canonical_id=band.id))
        await db.commit()

    with patch(f"{_SERVICE}.fetch_itunes_artist_songs", new=AsyncMock(return_value=["솔로곡"])):
        async with AsyncSessionLocal() as db:
            songs = await representative_songs_for_artist(db, "밴드멤버가수B", 20)

    assert [s["name"] for s in songs] == ["솔로곡"]


@pytest.mark.asyncio
async def test_none_anchor_disables_representative_songs():
    # "대표곡 해당 없음"으로 확정된 아티스트는 iTunes/Last.fm 모두 안 씀(Last.fm도 동명이인이 잡혀서
    # 확정한 경우가 있음 - 실사례: 김정훈)
    async with AsyncSessionLocal() as db:
        db.add(CanonicalArtist(mbid="mbid-none-a", canonical_name="없음확정가수A", anchor_confirmed_by="none"))
        await db.commit()

    apple = AsyncMock(return_value="931")
    candidates = AsyncMock(return_value=[_candidate("932", True)])
    lastfm = AsyncMock(return_value=("", _tracks(6, top_listeners=5000)))
    with patch(f"{_SERVICE}.fetch_apple_music_artist_id", new=apple), patch(
        f"{_SERVICE}.search_itunes_artists", new=candidates
    ), patch(f"{_SERVICE}.fetch_top_tracks", new=lastfm):
        async with AsyncSessionLocal() as db:
            assert await representative_songs_for_artist(db, "없음확정가수A", 20) == []

    apple.assert_not_awaited()
    candidates.assert_not_awaited()
    lastfm.assert_not_awaited()


# 예상 셋리 생성에 연결 - 과거 셋리가 없으면 대표곡으로 채움

@pytest.mark.asyncio
async def test_generate_pre_setlist_falls_back_to_representative():
    concert_id = await _create_concert("PF_REP_GEN_001", artist="대표곡가수F")
    await _add_canonical("대표곡가수F", itunes_artist_id="333")
    token = await _get_token()

    with _setlistfm_not_found(), _lastfm("", []), patch(
        f"{_SERVICE}.fetch_itunes_artist_songs", new=AsyncMock(return_value=["곡1", "곡2"])
    ):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/setlist/pre/generate",
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 201
    assert [(s["name"], s["source"]) for s in response.json()["songs"]] == [
        ("곡1", "representative"),
        ("곡2", "representative"),
    ]


# 앵커(유저가 곡 1개로 아티스트 확정)

@pytest.mark.asyncio
async def test_anchor_candidates_search():
    concert_id = await _create_concert("PF_REP_ANCHOR_001", artist="앵커가수A")
    token = await _get_token()
    ticket_id = await _create_ticket(concert_id, token)

    itunes_response = MagicMock()
    itunes_response.status_code = 200
    itunes_response.json = MagicMock(return_value={"results": [
        {"artistId": 444, "artistName": "Anchor A", "trackName": "Song", "collectionName": "Album",
         "artworkUrl100": "https://example.com/a.jpg"},
        {"artistName": "No Id", "trackName": "Skipped"},
    ]})
    client = MagicMock()
    client.__aenter__ = AsyncMock(return_value=client)
    client.__aexit__ = AsyncMock(return_value=None)
    client.get = AsyncMock(return_value=itunes_response)
    with patch(f"{_SERVICE}.httpx.AsyncClient", return_value=client):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                f"/api/v1/tickets/{ticket_id}/setlist/pre/anchor-candidates",
                params={"song": "Song"},
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 200
    assert response.json() == [{
        "itunes_artist_id": "444", "artist_name": "Anchor A", "track_name": "Song",
        "album_name": "Album", "artwork_url": "https://example.com/a.jpg",
    }]


@pytest.mark.asyncio
async def test_anchor_creates_canonical_and_fills_pre_setlist():
    # canonical이 없던(MusicBrainz 미등록) 아티스트도 앵커로 새로 만들어 확정
    concert_id = await _create_concert("PF_REP_ANCHOR_002", artist="앵커가수B")
    token = await _get_token()
    ticket_id = await _create_ticket(concert_id, token)

    with _setlistfm_not_found(), _lastfm("", []), patch(
        f"{_SERVICE}.fetch_itunes_artist_name", new=AsyncMock(return_value="Anchor B")
    ), patch(f"{_SERVICE}.fetch_itunes_artist_songs", new=AsyncMock(return_value=["곡X", "곡Y"])):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/tickets/{ticket_id}/setlist/pre/anchor",
                json={"artist": "앵커가수B", "itunes_artist_id": "555"},
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 200
    assert [(s["name"], s["source"]) for s in response.json()["songs"]] == [
        ("곡X", "representative"),
        ("곡Y", "representative"),
    ]
    canonical = await _get_canonical("앵커가수B")
    assert canonical.itunes_artist_id == "555"
    assert canonical.anchor_confirmed_by == "user"


@pytest.mark.asyncio
async def test_anchor_keeps_user_edited_pre_setlist():
    concert_id = await _create_concert("PF_REP_ANCHOR_003", artist="앵커가수C")
    token = await _get_token()
    ticket_id = await _create_ticket(concert_id, token)
    async with AsyncSessionLocal() as db:
        db.add(PreSetlist(
            concert_id=concert_id, songs=[{"name": "유저가넣은곡", "encore": False}], is_user_edited=True
        ))
        await db.commit()

    with _setlistfm_not_found(), _lastfm("", []), patch(
        f"{_SERVICE}.fetch_itunes_artist_name", new=AsyncMock(return_value="Anchor C")
    ), patch(f"{_SERVICE}.fetch_itunes_artist_songs", new=AsyncMock(return_value=["곡X"])):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/tickets/{ticket_id}/setlist/pre/anchor",
                json={"artist": "앵커가수C", "itunes_artist_id": "666"},
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 200
    assert [s["name"] for s in response.json()["songs"]] == ["유저가넣은곡"]
    assert (await _get_canonical("앵커가수C")).itunes_artist_id == "666"


@pytest.mark.asyncio
async def test_anchor_rejects_artist_not_in_concert():
    concert_id = await _create_concert("PF_REP_ANCHOR_004", artist="앵커가수D")
    token = await _get_token()
    ticket_id = await _create_ticket(concert_id, token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            f"/api/v1/tickets/{ticket_id}/setlist/pre/anchor",
            json={"artist": "다른가수", "itunes_artist_id": "777"},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 400


@pytest.mark.asyncio
async def test_generate_pre_setlist_clears_stale_songs_when_nothing_left():
    # 예전에 채운 대표곡이 나중에 "해당 없음"으로 바뀌어 채울 게 없어지면 기존 곡도 비움
    concert_id = await _create_concert("PF_REP_STALE_001", artist="낡은대표곡가수")
    async with AsyncSessionLocal() as db:
        db.add(CanonicalArtist(canonical_name="낡은대표곡가수", anchor_confirmed_by="none"))
        db.add(PreSetlist(concert_id=concert_id, songs=[{"name": "남의곡", "source": "representative"}]))
        await db.commit()

    with _setlistfm_not_found():
        async with AsyncSessionLocal() as db:
            with pytest.raises(HTTPException) as exc:
                await generate_pre_setlist(db, concert_id)
    assert exc.value.status_code == 404

    async with AsyncSessionLocal() as db:
        row = (await db.execute(select(PreSetlist).where(PreSetlist.concert_id == concert_id))).scalar_one()
    assert row.songs == []


@pytest.mark.asyncio
async def test_generate_pre_setlist_keeps_user_edited_when_nothing_left():
    concert_id = await _create_concert("PF_REP_STALE_002", artist="낡은대표곡가수B")
    async with AsyncSessionLocal() as db:
        db.add(CanonicalArtist(canonical_name="낡은대표곡가수B", anchor_confirmed_by="none"))
        db.add(PreSetlist(concert_id=concert_id, songs=[{"name": "유저곡"}], is_user_edited=True))
        await db.commit()

    with _setlistfm_not_found():
        async with AsyncSessionLocal() as db:
            with pytest.raises(HTTPException):
                await generate_pre_setlist(db, concert_id)

    async with AsyncSessionLocal() as db:
        row = (await db.execute(select(PreSetlist).where(PreSetlist.concert_id == concert_id))).scalar_one()
    assert [s["name"] for s in row.songs] == ["유저곡"]
