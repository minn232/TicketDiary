from unittest.mock import AsyncMock, patch

import pytest
from fastapi import HTTPException
from httpx import AsyncClient, ASGITransport

from app.main import app


# 헬퍼

# 카카오 사용자 정보 모킹
_MOCK_KAKAO_USER = {
    "id": 12345678,
    "kakao_account": {
        "profile": {
            "nickname": "테스트",
            "thumbnail_image_url": "https://example.com/profile.jpg",
        }
    },
}

# 게스트 로그인 테스트

# 게스트 계정 생성 테스트
@pytest.mark.asyncio
async def test_guest_login_create_user():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post("/api/v1/auth/guest", json={"device_id": "test-device-001"})

    assert response.status_code == 200
    data = response.json()
    assert "access_token" in data
    assert data["token_type"] == "bearer"
    assert "user_id" in data
    assert data["role"] == "guest"


# 게스트 계정 동일 디바이스 로그인 테스트
@pytest.mark.asyncio
async def test_guest_login_same_login():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res1 = await ac.post("/api/v1/auth/guest", json={"device_id": "test-device-002"})
        res2 = await ac.post("/api/v1/auth/guest", json={"device_id": "test-device-002"})

    assert res1.json()["user_id"] == res2.json()["user_id"]


# 카카오 로그인 테스트

# 카카오 계정 생성 테스트
@pytest.mark.asyncio
async def test_kakao_login_new_user():
    with patch("app.services.auth._exchange_kakao_code", new=AsyncMock(return_value="mock-token")), \
         patch("app.services.auth._get_kakao_user_info", new=AsyncMock(return_value=_MOCK_KAKAO_USER)):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post("/api/v1/auth/kakao", json={"code": "kakao-auth-code-001"})

    assert response.status_code == 200
    data = response.json()
    assert "access_token" in data
    assert data["token_type"] == "bearer"
    assert "user_id" in data
    assert data["role"] == "kakao_user"


# 카카오 계정 동일 계정 로그인 테스트
@pytest.mark.asyncio
async def test_kakao_login_same_login():
    user_info = {**_MOCK_KAKAO_USER, "id": 22222222}

    with patch("app.services.auth._exchange_kakao_code", new=AsyncMock(return_value="mock-token")), \
         patch("app.services.auth._get_kakao_user_info", new=AsyncMock(return_value=user_info)):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res1 = await ac.post("/api/v1/auth/kakao", json={"code": "kakao-code-a"})
            res2 = await ac.post("/api/v1/auth/kakao", json={"code": "kakao-code-b"})

    assert res1.json()["user_id"] == res2.json()["user_id"]


# 카카오 로그인 유효하지 않은 코드 테스트
@pytest.mark.asyncio
async def test_kakao_login_invalid_code():
    with patch(
        "app.services.auth._exchange_kakao_code",
        new=AsyncMock(side_effect=HTTPException(status_code=400, detail="유효하지 않은 카카오 인증 코드입니다.")),
    ):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post("/api/v1/auth/kakao", json={"code": "invalid-code"})

    assert response.status_code == 400


# 카카오 로그인 재로그인 시 프로필 갱신 테스트
@pytest.mark.asyncio
async def test_kakao_login_updates_profile():
    kakao_id = 33333333
    first_info = {
        "id": kakao_id,
        "kakao_account": {"profile": {"nickname": "첫번째닉네임", "thumbnail_image_url": None}},
    }
    updated_info = {
        "id": kakao_id,
        "kakao_account": {"profile": {"nickname": "변경된닉네임", "thumbnail_image_url": "https://example.com/new.jpg"}},
    }

    with patch("app.services.auth._exchange_kakao_code", new=AsyncMock(return_value="mock-token")), \
         patch("app.services.auth._get_kakao_user_info", new=AsyncMock(side_effect=[first_info, updated_info])):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res1 = await ac.post("/api/v1/auth/kakao", json={"code": "code-first"})
            me1 = await ac.get("/api/v1/auth/me", headers={"Authorization": f"Bearer {res1.json()['access_token']}"},)

            res2 = await ac.post("/api/v1/auth/kakao", json={"code": "code-second"})
            me2 = await ac.get("/api/v1/auth/me", headers={"Authorization": f"Bearer {res2.json()['access_token']}"},)

    assert me1.json()["nickname"] == "첫번째닉네임"
    assert me2.json()["nickname"] == "변경된닉네임"
    assert res1.json()["user_id"] == res2.json()["user_id"]


# 카카오 OAuth 인증 URL 반환 테스트
@pytest.mark.asyncio
async def test_kakao_auth_url():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.get("/api/v1/auth/kakao/url")

    assert response.status_code == 200
    data = response.json()
    assert "url" in data
    assert "https://kauth.kakao.com/oauth/authorize" in data["url"]