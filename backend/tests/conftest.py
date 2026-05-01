import asyncio
import sys
import pytest_asyncio
from httpx import AsyncClient, ASGITransport
from app.main import app

# Windows에서 asyncio 에러 방지
if sys.platform == 'win32':
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())


@pytest_asyncio.fixture
async def get_auth_token():
    # 테스트용 게스트 로그인 토큰 발급
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post("/api/v1/auth/guest", json={"device_id": "fixture-device"})
    return response.json()["access_token"]
