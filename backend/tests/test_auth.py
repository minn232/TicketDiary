import pytest
from httpx import AsyncClient, ASGITransport
from app.main import app


@pytest.mark.asyncio
async def test_guest_login_create_user():
    # 새로운 device_id로 로그인
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post("/api/v1/auth/guest", json={"device_id": "test-device-001"})

    assert response.status_code == 200
    data = response.json()
    assert "access_token" in data
    assert data["token_type"] == "bearer"
    assert "user_id" in data
    assert data["role"] == "guest"


@pytest.mark.asyncio
async def test_guest_login_same_login():
    # 같은 device_id 로그인 동일한 user_id 반환
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res1 = await ac.post("/api/v1/auth/guest", json={"device_id": "test-device-002"})
        res2 = await ac.post("/api/v1/auth/guest", json={"device_id": "test-device-002"})

    assert res1.json()["user_id"] == res2.json()["user_id"]