import uuid
from contextlib import contextmanager
from datetime import date
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from app.main import app
from app.core.database import AsyncSessionLocal
from app.models.concert import Concert
from app.models.social import NewsFeed
from app.services.kopis import _fetch_all_kopis_ids, sync_daily_concerts
from conftest import _get_token, kopis_mock


# 헬퍼

# KOPIS 목록 API XML 생성 (kopis_id 목록 기반)
def _make_list_xml(kopis_ids: list[str]) -> bytes:
    dbs = ""
    for kid in kopis_ids:
        dbs += (
            f"<db>"
            f"<mt20id>{kid}</mt20id>"
            f"<prfnm>{kid} 공연</prfnm>"
            f"<prfpdfrom>2030.06.01</prfpdfrom>"
            f"<prfpdto>2030.06.30</prfpdto>"
            f"<fcltynm>테스트공연장</fcltynm>"
            f"<genrenm>대중음악</genrenm>"
            f"<poster></poster>"
            f"</db>"
        )
    return f'<?xml version="1.0" encoding="UTF-8"?><dbs>{dbs}</dbs>'.encode("utf-8")


# KOPIS 상세 API XML 생성 (아티스트 지정 가능)
def _make_detail_xml(kopis_id: str, artist: str = "테스트아티스트") -> bytes:
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f"<dbs><db>"
        f"<mt20id>{kopis_id}</mt20id>"
        f"<prfnm>{kopis_id} 공연</prfnm>"
        f"<prfpdfrom>2030.06.01</prfpdfrom>"
        f"<prfpdto>2030.06.30</prfpdto>"
        f"<fcltynm>테스트공연장</fcltynm>"
        f"<genrenm>대중음악</genrenm>"
        f"<prfcrew>출연: {artist}</prfcrew>"
        f"<pcseguidance></pcseguidance>"
        f"<sty></sty>"
        f"</db></dbs>"
    ).encode("utf-8")


# 목록 API와 상세 API를 URL 기반으로 구분하는 KOPIS mock
@contextmanager
def _batch_kopis_mock(list_xml: bytes, detail_xml: bytes):
    list_response = MagicMock()
    list_response.status_code = 200
    list_response.content = list_xml

    detail_response = MagicMock()
    detail_response.status_code = 200
    detail_response.content = detail_xml

    async def _mock_get(url, **kwargs):
        parts = url.split("/pblprfr/")
        if len(parts) > 1 and parts[1]:
            return detail_response
        return list_response

    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = _mock_get

    with patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client):
        yield


# _fetch_all_kopis_ids 테스트

# 21페이지 이상 존재해도 (구 상한 20페이지=2000건을 넘어) 끝까지 수집하는지 테스트
@pytest.mark.asyncio
async def test_fetch_all_kopis_ids_collects_beyond_old_page_cap():
    # 25페이지 100건씩(2500건) + 26페이지째 50건(마지막 페이지) = 총 2550건
    async def _mock_get(url, **kwargs):
        cpage = kwargs["params"]["cpage"]
        if cpage <= 25:
            ids = [f"PF_PAGE{cpage}_{i}" for i in range(100)]
        elif cpage == 26:
            ids = [f"PF_PAGE26_{i}" for i in range(50)]
        else:
            ids = []
        return MagicMock(status_code=200, content=_make_list_xml(ids))

    mock_client = MagicMock()
    mock_client.get = _mock_get

    ids = await _fetch_all_kopis_ids(mock_client, date(2030, 1, 1), date(2030, 12, 31))

    assert len(ids) == 2550


# sync_daily_concerts 테스트

# 신규 공연 DB 저장 및 아티스트 정보 포함 테스트
@pytest.mark.asyncio
async def test_sync_creates_new_concert():
    kopis_id = f"PF_BATCH_{uuid.uuid4().hex[:8]}"
    list_xml = _make_list_xml([kopis_id])
    detail_xml = _make_detail_xml(kopis_id, "배치테스트아티스트")

    with _batch_kopis_mock(list_xml, detail_xml), patch("asyncio.sleep"):
        async with AsyncSessionLocal() as db:
            await sync_daily_concerts(db)

    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Concert).where(Concert.kopis_id == kopis_id))
        concert = result.scalar_one_or_none()

    assert concert is not None
    assert "배치테스트아티스트" in concert.artist_name


# 신규 공연 + 팔로우 아티스트 일치 시 뉴스피드 생성 테스트
@pytest.mark.asyncio
async def test_sync_creates_newsfeed_for_followed_artist():
    artist_name = f"배치아티스트_{uuid.uuid4().hex[:6]}"
    kopis_id = f"PF_BATCH_{uuid.uuid4().hex[:8]}"
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    # 아티스트 팔로우 등록
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": artist_name}]},
            headers=headers,
        )

    list_xml = _make_list_xml([kopis_id])
    detail_xml = _make_detail_xml(kopis_id, artist_name)

    with _batch_kopis_mock(list_xml, detail_xml), patch("asyncio.sleep"):
        async with AsyncSessionLocal() as db:
            await sync_daily_concerts(db)

    # 뉴스피드 생성 확인
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/social/feed", headers=headers)

    assert res.status_code == 200
    feed = res.json()
    assert len(feed) == 1
    assert feed[0]["artist_name"] == artist_name
    assert feed[0]["is_read"] is False


# 미팔로우 아티스트 공연 신규 등록 시 뉴스피드 미생성 테스트
@pytest.mark.asyncio
async def test_sync_no_newsfeed_for_non_followed_artist():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}
    kopis_id = f"PF_BATCH_{uuid.uuid4().hex[:8]}"

    # 다른 아티스트만 팔로우
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": "팔로우안한아티스트"}]},
            headers=headers,
        )

    list_xml = _make_list_xml([kopis_id])
    detail_xml = _make_detail_xml(kopis_id, "전혀다른아티스트")

    with _batch_kopis_mock(list_xml, detail_xml), patch("asyncio.sleep"):
        async with AsyncSessionLocal() as db:
            await sync_daily_concerts(db)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/social/feed", headers=headers)

    assert res.status_code == 200
    assert res.json() == []


# 기존 공연 (artist_name 있음) -> 상세 API 재호출 없이 뉴스피드만 생성 테스트
@pytest.mark.asyncio
async def test_sync_skips_detail_api_for_existing_concert():
    artist_name = f"배치기존아티스트_{uuid.uuid4().hex[:6]}"
    kopis_id = f"PF_BATCH_{uuid.uuid4().hex[:8]}"
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    # 공연 먼저 DB에 생성 (상세 조회 경로)
    detail_xml = _make_detail_xml(kopis_id, artist_name)
    with kopis_mock(detail_xml):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.get(f"/api/v1/concerts/{kopis_id}", headers=headers)

    # 아티스트 팔로우 등록 (공연 생성 이후에 팔로우)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": artist_name}]},
            headers=headers,
        )

    # 상세 API 호출 횟수 추적
    detail_call_count = 0

    async def _mock_get(url, **kwargs):
        nonlocal detail_call_count
        parts = url.split("/pblprfr/")
        if len(parts) > 1 and parts[1]:
            detail_call_count += 1
            return MagicMock(status_code=200, content=detail_xml)
        return MagicMock(status_code=200, content=_make_list_xml([kopis_id]))

    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = _mock_get

    with patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client):
        async with AsyncSessionLocal() as db:
            await sync_daily_concerts(db)

    # 상세 API 재호출 없음
    assert detail_call_count == 0

    # 뉴스피드는 생성됨
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/social/feed", headers=headers)

    assert any(f["artist_name"] == artist_name for f in res.json())


# KOPIS 빈 응답 시 아무 변화 없음 테스트
@pytest.mark.asyncio
async def test_sync_handles_empty_kopis_response():
    empty_xml = b'<?xml version="1.0" encoding="UTF-8"?><dbs></dbs>'

    with _batch_kopis_mock(empty_xml, b""), patch("asyncio.sleep"):
        async with AsyncSessionLocal() as db:
            await sync_daily_concerts(db)

    # 예외 없이 정상 종료됨 (assert 없음 — 예외 발생 시 테스트 실패)


# 상세 조회가 일시적으로 실패(400)했다가 재시도 시 성공하면 공연이 정상 저장되는지 테스트
@pytest.mark.asyncio
async def test_sync_retries_transient_detail_failure():
    kopis_id = f"PF_BATCH_{uuid.uuid4().hex[:8]}"
    list_xml = _make_list_xml([kopis_id])
    detail_xml = _make_detail_xml(kopis_id, "재시도아티스트")

    call_count = 0

    async def _mock_get(url, **kwargs):
        nonlocal call_count
        parts = url.split("/pblprfr/")
        if len(parts) > 1 and parts[1]:
            call_count += 1
            if call_count == 1:
                return MagicMock(status_code=400, content=b"")
            return MagicMock(status_code=200, content=detail_xml)
        return MagicMock(status_code=200, content=list_xml)

    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = _mock_get

    with (
        patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client),
        patch("asyncio.sleep"),
    ):
        async with AsyncSessionLocal() as db:
            await sync_daily_concerts(db)

    assert call_count == 2

    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Concert).where(Concert.kopis_id == kopis_id))
        concert = result.scalar_one_or_none()

    assert concert is not None
    assert "재시도아티스트" in concert.artist_name


# 상세 조회가 재시도 횟수만큼 계속 실패하면 해당 공연은 포기하고 넘어가는지 테스트
@pytest.mark.asyncio
async def test_sync_gives_up_after_max_detail_retries():
    kopis_id = f"PF_BATCH_{uuid.uuid4().hex[:8]}"
    list_xml = _make_list_xml([kopis_id])

    call_count = 0

    async def _mock_get(url, **kwargs):
        nonlocal call_count
        parts = url.split("/pblprfr/")
        if len(parts) > 1 and parts[1]:
            call_count += 1
            return MagicMock(status_code=400, content=b"")
        return MagicMock(status_code=200, content=list_xml)

    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = _mock_get

    with (
        patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client),
        patch("asyncio.sleep"),
    ):
        async with AsyncSessionLocal() as db:
            await sync_daily_concerts(db)

    assert call_count == 3

    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Concert).where(Concert.kopis_id == kopis_id))
        concert = result.scalar_one_or_none()

    assert concert is None


# KOPIS 목록 API 실패 시 조기 종료 테스트
@pytest.mark.asyncio
async def test_sync_handles_kopis_list_api_failure():
    error_response = MagicMock()
    error_response.status_code = 500
    error_response.content = b""

    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = AsyncMock(return_value=error_response)

    with patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client):
        async with AsyncSessionLocal() as db:
            await sync_daily_concerts(db)

    # 예외 없이 정상 종료됨
