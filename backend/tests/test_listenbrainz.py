import uuid
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock, MagicMock, patch

import httpx
import pytest
from sqlalchemy import select

from app.core.database import AsyncSessionLocal
from app.models.artist_lastfm_sync_status import ArtistLastfmSyncStatus
from app.models.artist_normalization import ArtistAlias, CanonicalArtist
from app.models.artist_similarity import ArtistSimilarity
from app.services.listenbrainz import _to_scored_names, fetch_similar_artists, sync_artist_similarities
from conftest import _get_token
from test_recommendations import _create_concert, _insert_similarity, _set_lastfm_status

_SERVICE = "app.services.listenbrainz"


# 요청 간격을 없애고, 테스트 DB에 쌓인 다른 아티스트에 밀리지 않게 하루 상한을 크게 잡음
@pytest.fixture(autouse=True)
def _fast_sync():
    with patch(f"{_SERVICE}._REQUEST_INTERVAL", 0), patch(f"{_SERVICE}._MAX_LASTFM_SYNC_PER_RUN", 100000):
        yield


# 공연 1개와 canonical(선택적으로 alias)을 만들어 (공연 표기, mbid) 반환
async def _artist(prefix: str, mbid: bool = True, canonical_name: str | None = None) -> tuple[str, str | None]:
    name = f"{prefix}_{uuid.uuid4().hex[:8]}"
    artist_mbid = str(uuid.uuid4()) if mbid else None
    await _create_concert(f"PF_LB_{uuid.uuid4().hex[:8]}", name, await _get_token())
    async with AsyncSessionLocal() as db:
        canonical = CanonicalArtist(mbid=artist_mbid, canonical_name=canonical_name or name)
        db.add(canonical)
        await db.flush()
        if canonical_name:
            db.add(ArtistAlias(canonical_artist_id=canonical.id, alias_text=name, source="musicbrainz"))
        await db.commit()
    return name, artist_mbid


# 대상 mbid에만 지정한 결과를 주고 나머지는 빈 결과인 가짜 조회
def _fetch_mock(results: dict) -> AsyncMock:
    return AsyncMock(side_effect=lambda mbid: results.get(mbid, []))


async def _similar_rows(artist_name: str) -> dict[str, float]:
    async with AsyncSessionLocal() as db:
        rows = await db.execute(select(ArtistSimilarity).where(ArtistSimilarity.artist_name == artist_name))
        return {r.similar_artist_name: r.match_score for r in rows.scalars().all()}


async def _status(artist_name: str, sync_type: str = "lb_similarity") -> ArtistLastfmSyncStatus | None:
    async with AsyncSessionLocal() as db:
        rows = await db.execute(
            select(ArtistLastfmSyncStatus).where(
                ArtistLastfmSyncStatus.artist_name == artist_name,
                ArtistLastfmSyncStatus.sync_type == sync_type,
            )
        )
        return rows.scalar_one_or_none()


def _http_mock(response=None, error=None):
    client = MagicMock()
    client.__aenter__ = AsyncMock(return_value=client)
    client.__aexit__ = AsyncMock(return_value=None)
    client.get = AsyncMock(return_value=response, side_effect=error)
    return patch(f"{_SERVICE}.httpx.AsyncClient", return_value=client)


@pytest.mark.asyncio
async def test_fetch_similar_artists_parses_entries():
    response = MagicMock(json=MagicMock(return_value=[
        {"artist_mbid": "m1", "name": "A", "score": 200},
        {"name": "mbid 없음", "score": 100},
    ]))
    with _http_mock(response):
        assert await fetch_similar_artists("seed") == [("m1", "A", 200.0)]


# 호출 실패/예상 밖 응답은 "결과 없음"(빈 리스트)과 구분해 None
@pytest.mark.asyncio
async def test_fetch_similar_artists_failure_returns_none():
    with _http_mock(error=httpx.ConnectError("down")):
        assert await fetch_similar_artists("seed") is None
    with _http_mock(MagicMock(json=MagicMock(return_value={"error": "x"}))):
        assert await fetch_similar_artists("seed") is None


def test_to_scored_names_normalizes_dedupes_and_excludes_self():
    similar = [("seed", "나", 9000.0), ("m1", "IU", 2000.0), ("m2", "Same", 1000.0), ("m3", "same", 500.0)]

    assert _to_scored_names("seed", similar, {"m1": "아이유"}) == [("아이유", 1.0), ("Same", 0.5)]
    assert _to_scored_names("seed", [("m1", "A", 0.0)], {}) == []


# 별칭으로 mbid를 찾고, 결과는 mbid로 공연 표기에 맞춰 0~1 점수로 저장
@pytest.mark.asyncio
async def test_sync_stores_concert_spelling_and_normalized_score():
    seed, seed_mbid = await _artist("LB씨앗")
    other, other_mbid = await _artist("LB공연표기", canonical_name=f"Canonical_{uuid.uuid4().hex[:8]}")
    fetch = _fetch_mock({seed_mbid: [(other_mbid, "LB Name", 400.0), (str(uuid.uuid4()), "Unknown", 100.0)]})

    with patch(f"{_SERVICE}.fetch_similar_artists", fetch):
        await sync_artist_similarities()

    assert await _similar_rows(seed) == {other: 1.0, "Unknown": 0.25}


@pytest.mark.asyncio
async def test_sync_skips_artist_without_mbid_and_fresh_cache():
    no_mbid, _ = await _artist("LB엠비드없음", mbid=False)
    cached, cached_mbid = await _artist("LB캐시있음")
    await _insert_similarity(cached, "기존", 0.5)
    fetch = _fetch_mock({})

    with patch(f"{_SERVICE}.fetch_similar_artists", fetch):
        await sync_artist_similarities()

    assert cached_mbid not in {c.args[0] for c in fetch.await_args_list}
    assert await _status(no_mbid) is None


# Last.fm 때의 실패 기록은 새 조회를 막지 않고, 결과가 없으면 오래된 캐시를 남긴 채 새 구분값으로 기록
@pytest.mark.asyncio
async def test_sync_empty_result_keeps_old_cache_and_records_failure():
    artist, mbid = await _artist("LB결과없음")
    await _insert_similarity(artist, "옛결과", 0.7, fetched_at=datetime.now(timezone.utc) - timedelta(days=181))
    await _set_lastfm_status(artist, "similarity", datetime.now(timezone.utc), 5)
    fetch = _fetch_mock({})

    with patch(f"{_SERVICE}.fetch_similar_artists", fetch):
        await sync_artist_similarities()
        await sync_artist_similarities()  # 쿨다운 안이라 재조회 안 함

    assert [c.args[0] for c in fetch.await_args_list].count(mbid) == 1
    assert await _similar_rows(artist) == {"옛결과": 0.7}
    assert (await _status(artist)).attempt_count == 1


# 호출이 연속 실패하면 중단하고 실패 기록(쿨다운)을 남기지 않음
@pytest.mark.asyncio
async def test_sync_stops_on_consecutive_errors_without_recording_failure():
    for i in range(7):
        await _artist(f"LB장애{i}")
    fetch = AsyncMock(return_value=None)
    record = AsyncMock()

    with patch(f"{_SERVICE}.fetch_similar_artists", fetch), patch(f"{_SERVICE}._record_lastfm_failure", record):
        await sync_artist_similarities()

    assert fetch.await_count == 5
    record.assert_not_awaited()
