import pytest
from httpx import AsyncClient, ASGITransport

from app.main import app
from conftest import _get_token


# 유저 설정 조회 테스트

# 신규 유저 기본 설정 조회 테스트
@pytest.mark.asyncio
async def test_get_settings_default():
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/settings", headers={"Authorization": f"Bearer {token}"})

    assert res.status_code == 200
    data = res.json()
    assert data["fcm_token"] is None
    assert data["show_predicted_setlist"] is True
    assert data["notification_settings"]["delivery"] is True
    assert data["notification_settings"]["before_concert"] is True


# 미인증 요청 401 테스트
@pytest.mark.asyncio
async def test_get_settings_no_auth_401():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/settings")

    assert res.status_code == 401


# 유저 설정 수정 테스트

# show_predicted_setlist 수정 성공 테스트
@pytest.mark.asyncio
async def test_update_settings_show_predicted_setlist():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.patch(
            "/api/v1/settings",
            json={"show_predicted_setlist": False},
            headers=headers,
        )

    assert res.status_code == 200
    assert res.json()["show_predicted_setlist"] is False


# notification_settings 수정 성공 테스트
@pytest.mark.asyncio
async def test_update_settings_notification_settings():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.patch(
            "/api/v1/settings",
            json={"notification_settings": {"delivery": False, "before_concert": True}},
            headers=headers,
        )

    assert res.status_code == 200
    data = res.json()
    assert data["notification_settings"]["delivery"] is False
    assert data["notification_settings"]["before_concert"] is True


# 부분 수정 시 나머지 설정 유지 테스트
@pytest.mark.asyncio
async def test_update_settings_partial_keeps_others():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch("/api/v1/settings", json={"show_predicted_setlist": False}, headers=headers)
        res = await ac.get("/api/v1/settings", headers=headers)

    data = res.json()
    assert data["show_predicted_setlist"] is False
    assert data["notification_settings"]["delivery"] is True
    assert data["notification_settings"]["before_concert"] is True


# 수정 후 재조회 시 반영 확인 테스트
@pytest.mark.asyncio
async def test_update_settings_persisted():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/settings",
            json={
                "show_predicted_setlist": False,
                "notification_settings": {"delivery": False, "before_concert": False},
            },
            headers=headers,
        )
        res = await ac.get("/api/v1/settings", headers=headers)

    data = res.json()
    assert data["show_predicted_setlist"] is False
    assert data["notification_settings"]["delivery"] is False
    assert data["notification_settings"]["before_concert"] is False


# 미인증 요청 401 테스트
@pytest.mark.asyncio
async def test_update_settings_no_auth_401():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.patch("/api/v1/settings", json={"show_predicted_setlist": False})

    assert res.status_code == 401


# FCM 토큰 업데이트 테스트

# FCM 토큰 업데이트 성공 테스트
@pytest.mark.asyncio
async def test_update_fcm_token_success():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.patch(
            "/api/v1/settings/fcm-token",
            json={"fcm_token": "my-fcm-token-abc123"},
            headers=headers,
        )

    assert res.status_code == 200
    assert res.json()["fcm_token"] == "my-fcm-token-abc123"


# FCM 토큰 재업데이트 성공 테스트
@pytest.mark.asyncio
async def test_update_fcm_token_overwrite():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch("/api/v1/settings/fcm-token", json={"fcm_token": "first-token"}, headers=headers)
        res = await ac.patch("/api/v1/settings/fcm-token", json={"fcm_token": "second-token"}, headers=headers)

    assert res.status_code == 200
    assert res.json()["fcm_token"] == "second-token"


# FCM 토큰 업데이트 후 재조회 시 반영 확인 테스트
@pytest.mark.asyncio
async def test_update_fcm_token_persisted():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch("/api/v1/settings/fcm-token", json={"fcm_token": "persisted-token"}, headers=headers)
        res = await ac.get("/api/v1/settings", headers=headers)

    assert res.json()["fcm_token"] == "persisted-token"


# 미인증 요청 401 테스트
@pytest.mark.asyncio
async def test_update_fcm_token_no_auth_401():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.patch("/api/v1/settings/fcm-token", json={"fcm_token": "some-token"})

    assert res.status_code == 401
