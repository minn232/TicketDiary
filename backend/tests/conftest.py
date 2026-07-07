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
