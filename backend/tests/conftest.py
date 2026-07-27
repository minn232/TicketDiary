import asyncio
import sys
import uuid
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from app.main import app

# Windows에서 asyncio 에러 방지
if sys.platform == 'win32':
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())


# 테스트마다 DB 연결 풀 초기화
@pytest_asyncio.fixture(autouse=True)
async def _reset_db_pool():
    # 테스트 전

    yield

    # 테스트 후 DB 연결 풀 종료
    from app.core.database import engine
    await engine.dispose()


# 테스트마다 인메모리 rate limit 상태 초기화 (get_auth_token 픽스처가 고정 device_id를 써서
# 여러 테스트가 같은 유저를 공유하므로, 안 지우면 한 테스트의 호출 횟수가 다른 테스트에 새어나감)
@pytest.fixture(autouse=True)
def _reset_rate_limits():
    from app.core.deps import _rate_limit_hits
    _rate_limit_hits.clear()
    yield


# 티켓 등록(POST /tickets)이 백그라운드로 Last.fm 장르 즉시 캐싱(ensure_artist_genres_cached)을
# 트리거하는데, 이걸 기본으로 막아두지 않으면 티켓을 만드는 모든 테스트가 로컬 .env의 진짜
# LASTFM_API_KEY로 실제 네트워크 호출을 하게 됨(느려지고, 테스트용 아티스트명이 실제 캐시
# 테이블에 쌓임). fetch_top_tags 자체를 patch하지 않고 API 키만 빈 값으로 덮어써서, 이 함수의
# "키 없으면 빈 리스트" 동작(정상 동작)을 그대로 타게 함 - fetch_top_tags 내부 로직을 직접
# 테스트하는 케이스는 거기서 다시 settings.LASTFM_API_KEY를 patch해서 오버라이드하면 됨
@pytest.fixture(autouse=True)
def _stub_lastfm_genre_fetch():
    with patch("app.services.lastfm.settings.LASTFM_API_KEY", ""):
        yield


# 테스트용 게스트 인증 토큰을 반환하는 픽스처
@pytest_asyncio.fixture
async def get_auth_token():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post("/api/v1/auth/guest", json={"device_id": "fixture-device"})
    return response.json()["access_token"]



# 헬퍼

# 테스트용 토큰 생성 함수
async def _get_token() -> str:
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post("/api/v1/auth/guest", json={"device_id": uuid.uuid4().hex})
    return response.json()["access_token"]


# kopis_mock 헬퍼
def kopis_mock(content: bytes, status_code: int = 200):
    mock_response = MagicMock()
    mock_response.status_code = status_code
    mock_response.content = content
    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = AsyncMock(return_value=mock_response)
    return patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client)
