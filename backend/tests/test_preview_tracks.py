import asyncio
import uuid
from datetime import date, datetime, timedelta, timezone
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport
from sqlalchemy import delete, select

from app.core.database import AsyncSessionLocal
from app.main import app
from app.models.itunes_catalog_cache import ItunesCatalogCache
from app.models.setlist import PreSetlist, RealSetlist
from app.services.preview_tracks import _fetch_catalog, _get_catalog, _interleave, get_preview_tracks
from conftest import _get_token
from test_pre_setlists import _create_concert

_SERVICE = "app.services.preview_tracks"
_SHOW_DATE = date(2030, 6, 1)


# 같은 iTunes ID(10)를 여러 테스트가 쓰므로 캐시가 다음 테스트로 새지 않게 비움
@pytest_asyncio.fixture(autouse=True)
async def _clear_catalog_cache():
    async with AsyncSessionLocal() as db:
        await db.execute(delete(ItunesCatalogCache))
        await db.commit()
    yield


# 헬퍼

def _cat(track_id: int, us_name: str, kr_name: str | None = None) -> dict:
    return {
        "track_id": track_id,
        "us_name": us_name,
        "kr_name": kr_name or us_name,
        "preview_url": f"https://audio.example.com/{track_id}.m4a",
        "track_view_url": f"https://music.example.com/{track_id}",
    }


_CATALOG = [_cat(1, "Alpha"), _cat(2, "Beta (feat. Someone)"), _cat(3, "Gamma", "감마"), _cat(4, "Delta")]


def _patch_catalog(tracks: list[dict] | None = None, itunes_id: str | None = "10"):
    return (
        patch(f"{_SERVICE}.resolve_itunes_artist_id_for", new=AsyncMock(return_value=itunes_id)),
        patch(f"{_SERVICE}._fetch_catalog", new=AsyncMock(return_value=_CATALOG if tracks is None else tracks)),
    )


async def _preview(concert_id: str) -> dict:
    async with AsyncSessionLocal() as db:
        return await get_preview_tracks(db, uuid.UUID(concert_id))


async def _add_real(concert_id: str, songs: list[dict]) -> None:
    async with AsyncSessionLocal() as db:
        db.add(RealSetlist(concert_id=uuid.UUID(concert_id), performance_date=_SHOW_DATE, songs=songs))
        await db.commit()


async def _add_pre(concert_id: str, songs: list[dict]) -> None:
    async with AsyncSessionLocal() as db:
        db.add(PreSetlist(concert_id=uuid.UUID(concert_id), songs=songs))
        await db.commit()


def _names(result: dict) -> list[str]:
    return [t["track_name"] for t in result["tracks"]]


# 곡 선택 순서

@pytest.mark.asyncio
async def test_real_setlist_matched_first_with_feat_and_korean_title():
    concert_id = await _create_concert("PV0001", "미리듣기가수")
    await _add_real(concert_id, [{"name": "Beta"}, {"name": "감마"}, {"name": "없는곡"}])
    await _add_pre(concert_id, [{"name": "Alpha"}])
    ids, fetch = _patch_catalog()
    with ids, fetch:
        result = await _preview(concert_id)

    # 실제 셋리가 pre보다 우선, feat 표기 차이와 한글 제목 모두 매칭, 못 맞춘 곡은 빠짐
    assert result["source"] == "real"
    assert _names(result) == ["Beta (feat. Someone)", "감마"]
    assert result["tracks"][0]["artist_name"] == "미리듣기가수"


@pytest.mark.asyncio
async def test_falls_back_to_pre_setlist_when_real_has_no_match():
    concert_id = await _create_concert("PV0002", "미리듣기가수")
    await _add_real(concert_id, [{"name": "없는곡"}])
    await _add_pre(concert_id, [{"name": "Alpha"}, {"name": "Delta"}])
    ids, fetch = _patch_catalog()
    with ids, fetch:
        result = await _preview(concert_id)

    assert result["source"] == "pre"
    assert _names(result) == ["Alpha", "Delta"]


@pytest.mark.asyncio
async def test_falls_back_to_catalog_without_setlists():
    concert_id = await _create_concert("PV0003", "미리듣기가수")
    ids, fetch = _patch_catalog()
    with ids, fetch:
        result = await _preview(concert_id)

    assert result["source"] == "catalog"
    assert _names(result) == ["Alpha", "Beta (feat. Someone)", "감마", "Delta"]


@pytest.mark.asyncio
async def test_artist_without_itunes_id_is_skipped():
    concert_id = await _create_concert("PV0004", "미리듣기가수")
    ids, fetch = _patch_catalog(itunes_id=None)
    with ids, fetch as fetch_mock:
        result = await _preview(concert_id)

    # 이름 검색으로 다른 아티스트 곡을 가져오지 않고 조회 자체를 안 함
    assert result == {"source": None, "tracks": []}
    fetch_mock.assert_not_called()


# 캐시

@pytest.mark.asyncio
async def test_catalog_cache_reused_within_seven_days():
    concert_id = await _create_concert("PV0005", "미리듣기가수")
    ids, fetch = _patch_catalog()
    with ids, fetch as fetch_mock:
        await _preview(concert_id)
        await _preview(concert_id)

    assert fetch_mock.await_count == 1


@pytest.mark.asyncio
async def test_stale_cache_is_refetched():
    concert_id = await _create_concert("PV0006", "미리듣기가수")
    ids, fetch = _patch_catalog()
    with ids, fetch as fetch_mock:
        await _preview(concert_id)
        async with AsyncSessionLocal() as db:
            row = (await db.execute(select(ItunesCatalogCache))).scalar_one()
            row.fetched_at = datetime.now(timezone.utc) - timedelta(days=8)
            await db.commit()
        await _preview(concert_id)

    assert fetch_mock.await_count == 2


# 같은 아티스트를 동시에 처음 열어도(둘 다 캐시 없음) 유니크 충돌 없이 한 행으로 저장
@pytest.mark.asyncio
async def test_concurrent_first_fetch_does_not_conflict():
    # 두 요청이 모두 "캐시 없음"을 확인한 뒤에야 저장으로 넘어가게 맞춤
    barrier = asyncio.Barrier(2)

    async def _slow_fetch(_itunes_artist_id):
        await asyncio.wait_for(barrier.wait(), timeout=5)
        return _CATALOG

    async def _get() -> list[dict]:
        async with AsyncSessionLocal() as db:
            return await _get_catalog(db, "10")

    with patch(f"{_SERVICE}._fetch_catalog", new=_slow_fetch):
        results = await asyncio.gather(_get(), _get())

    assert results == [_CATALOG, _CATALOG]
    async with AsyncSessionLocal() as db:
        assert len((await db.execute(select(ItunesCatalogCache))).all()) == 1


@pytest.mark.asyncio
async def test_fetch_failure_is_not_cached():
    concert_id = await _create_concert("PV0007", "미리듣기가수")
    ids = patch(f"{_SERVICE}.resolve_itunes_artist_id_for", new=AsyncMock(return_value="10"))
    with ids, patch(f"{_SERVICE}._fetch_catalog", new=AsyncMock(return_value=None)):
        result = await _preview(concert_id)
    assert result == {"source": None, "tracks": []}
    async with AsyncSessionLocal() as db:
        assert (await db.execute(select(ItunesCatalogCache))).first() is None


# iTunes 응답 정리

def _itunes_client(us: list[dict], kr: list[dict]):
    async def _get(url, params=None):
        response = MagicMock()
        response.raise_for_status = MagicMock()
        results = us if params.get("country") == "us" else kr
        response.json = MagicMock(return_value={"results": results})
        return response

    client = MagicMock()
    client.__aenter__ = AsyncMock(return_value=client)
    client.__aexit__ = AsyncMock(return_value=None)
    client.get = AsyncMock(side_effect=_get)
    return patch(f"{_SERVICE}.httpx.AsyncClient", return_value=client)


def _itunes_track(track_id: int, artist_id: int, title: str, preview: str | None = "https://a/p.m4a") -> dict:
    row = {"wrapperType": "track", "trackId": track_id, "artistId": artist_id, "trackName": title,
           "trackViewUrl": f"https://music/{track_id}"}
    if preview:
        row["previewUrl"] = preview
    return row


@pytest.mark.asyncio
async def test_fetch_catalog_filters_and_uses_kr_titles():
    us = [
        _itunes_track(1, 10, "Summer"),
        _itunes_track(2, 99, "Other Song"),  # 남의 곡
        _itunes_track(3, 10, "Summer (Live)"),  # 다른 버전
        _itunes_track(4, 10, "No Preview", preview=None),
    ]
    kr = [_itunes_track(1, 10, "여름")]
    with _itunes_client(us, kr):
        tracks = await _fetch_catalog("10")

    assert [(t["kr_name"], t["us_name"]) for t in tracks] == [("여름", "Summer")]


# 페스티벌 다양성

def test_interleave_alternates_artists_before_limit():
    tracks = [{"artist_name": a, "track_name": f"{a}{i}"} for a in "ABC" for i in range(4)]
    result = _interleave(tracks, 5)

    # 앞 아티스트 곡만 나오지 않고 A, B, C 순으로 번갈아 나옴
    assert [t["track_name"] for t in result] == ["A0", "B0", "C0", "A1", "B1"]


def test_interleave_continues_with_remaining_artist_when_others_run_out():
    tracks = [{"artist_name": "A", "track_name": "A0"}] + [
        {"artist_name": "B", "track_name": f"B{i}"} for i in range(3)
    ]
    assert [t["track_name"] for t in _interleave(tracks, 10)] == ["A0", "B0", "B1", "B2"]


# 엔드포인트

@pytest.mark.asyncio
async def test_endpoint_requires_ownership_and_returns_tracks():
    token = await _get_token()
    concert_id = await _create_concert("PV0008", "미리듣기가수")
    headers = {"Authorization": f"Bearer {token}"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        created = await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)
        ticket_id = created.json()["id"]
        ids, fetch = _patch_catalog()
        with ids, fetch:
            response = await ac.get(f"/api/v1/tickets/{ticket_id}/preview-tracks", headers=headers)
        missing = await ac.get(f"/api/v1/tickets/{uuid.uuid4()}/preview-tracks", headers=headers)

    assert response.status_code == 200
    assert response.json()["source"] == "catalog"
    assert response.json()["tracks"][0]["preview_url"].endswith("1.m4a")
    assert missing.status_code == 404
