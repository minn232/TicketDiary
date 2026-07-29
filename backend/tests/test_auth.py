from unittest.mock import AsyncMock, patch

import pytest
from fastapi import HTTPException
from httpx import AsyncClient, ASGITransport

from app.main import app
from conftest import _get_token


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


# IP당 시간당 요청 상한 초과 시 429 테스트 (device_id 브루트포스 방지)
@pytest.mark.asyncio
async def test_guest_login_rate_limited_after_20_calls_per_hour():
    statuses = []
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        for i in range(21):
            res = await ac.post("/api/v1/auth/guest", json={"device_id": f"rate-limit-device-{i}"})
            statuses.append(res.status_code)

    assert statuses[:20] == [200] * 20
    assert statuses[20] == 429


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


# 리프레시 토큰 테스트

# 로그인 응답에 리프레시 토큰이 함께 내려오는지 확인
@pytest.mark.asyncio
async def test_login_returns_refresh_token():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post("/api/v1/auth/guest", json={"device_id": "refresh-device-001"})

    data = response.json()
    assert "refresh_token" in data
    assert data["refresh_token"]


# 리프레시 토큰으로 재발급 시 새 access/refresh 토큰을 받는지 확인
@pytest.mark.asyncio
async def test_refresh_issues_new_tokens():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        login_res = await ac.post("/api/v1/auth/guest", json={"device_id": "refresh-device-002"})
        old_refresh = login_res.json()["refresh_token"]

        refresh_res = await ac.post("/api/v1/auth/refresh", json={"refresh_token": old_refresh})

    assert refresh_res.status_code == 200
    new_data = refresh_res.json()
    assert new_data["access_token"]
    assert new_data["refresh_token"] != old_refresh
    assert new_data["user_id"] == login_res.json()["user_id"]


# 회전(rotation): 재발급에 이미 쓴 리프레시 토큰은 재사용 불가
@pytest.mark.asyncio
async def test_refresh_token_rotation_rejects_reuse():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        login_res = await ac.post("/api/v1/auth/guest", json={"device_id": "refresh-device-003"})
        old_refresh = login_res.json()["refresh_token"]

        await ac.post("/api/v1/auth/refresh", json={"refresh_token": old_refresh})
        reuse_res = await ac.post("/api/v1/auth/refresh", json={"refresh_token": old_refresh})

    assert reuse_res.status_code == 401


# 존재하지 않는 리프레시 토큰으로 재발급 시도
@pytest.mark.asyncio
async def test_refresh_with_invalid_token():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post("/api/v1/auth/refresh", json={"refresh_token": "not-a-real-token"})

    assert response.status_code == 401


# 로그아웃 후 해당 리프레시 토큰으로 재발급 불가
@pytest.mark.asyncio
async def test_logout_revokes_refresh_token():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        login_res = await ac.post("/api/v1/auth/guest", json={"device_id": "refresh-device-004"})
        refresh_token = login_res.json()["refresh_token"]

        logout_res = await ac.post("/api/v1/auth/logout", json={"refresh_token": refresh_token})
        assert logout_res.status_code == 204

        refresh_res = await ac.post("/api/v1/auth/refresh", json={"refresh_token": refresh_token})

    assert refresh_res.status_code == 401


# 로그아웃은 이미 폐기되었거나 존재하지 않는 토큰이어도 항상 성공 처리
@pytest.mark.asyncio
async def test_logout_is_idempotent():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post("/api/v1/auth/logout", json={"refresh_token": "unknown-token"})

    assert response.status_code == 204


# 회원 프로필 수정 테스트

# 닉네임 수정 성공 테스트
@pytest.mark.asyncio
async def test_update_profile_nickname():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.patch("/api/v1/auth/me", json={"nickname": "새닉네임"}, headers=headers)

    assert res.status_code == 200
    assert res.json()["nickname"] == "새닉네임"


# 프로필 이미지 수정 성공 테스트
@pytest.mark.asyncio
async def test_update_profile_image_url():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.patch(
            "/api/v1/auth/me",
            json={"profile_image_url": "https://example.com/new.jpg"},
            headers=headers,
        )

    assert res.status_code == 200
    assert res.json()["profile_image_url"] == "https://example.com/new.jpg"


# 부분 수정 시 나머지 필드 유지 테스트
@pytest.mark.asyncio
async def test_update_profile_partial_keeps_others():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/auth/me",
            json={"nickname": "닉네임A", "profile_image_url": "https://example.com/a.jpg"},
            headers=headers,
        )
        res = await ac.patch("/api/v1/auth/me", json={"nickname": "닉네임B"}, headers=headers)

    data = res.json()
    assert data["nickname"] == "닉네임B"
    assert data["profile_image_url"] == "https://example.com/a.jpg"


# 수정 후 재조회 시 반영 확인 테스트
@pytest.mark.asyncio
async def test_update_profile_persisted():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch("/api/v1/auth/me", json={"nickname": "지속닉네임"}, headers=headers)
        res = await ac.get("/api/v1/auth/me", headers=headers)

    assert res.json()["nickname"] == "지속닉네임"


# 미인증 요청 401 테스트
@pytest.mark.asyncio
async def test_update_profile_no_auth_401():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.patch("/api/v1/auth/me", json={"nickname": "닉네임"})

    assert res.status_code == 401