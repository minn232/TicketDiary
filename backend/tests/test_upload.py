import io
from unittest.mock import patch

import pytest
from httpx import AsyncClient, ASGITransport

from app.main import app
from conftest import _get_token

_FAKE_S3_URL = "https://ticketdiary-images.s3.ap-northeast-2.amazonaws.com/ticket-images/test.jpg"
_SMALL_JPEG = b"\xff\xd8\xff\xe0" + b"x" * 100  # 최소 JPEG 헤더 포함 더미 데이터


# 헬퍼

# S3 업로드 mock (실제 S3 호출 없이 URL 반환)
def _s3_mock(url: str = _FAKE_S3_URL):
    return patch("app.services.storage._do_upload", return_value=url)


# 티켓 이미지 업로드 테스트

# 티켓 이미지 업로드 성공 테스트
@pytest.mark.asyncio
async def test_upload_ticket_image_success():
    token = await _get_token()

    with _s3_mock():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                "/api/v1/upload/ticket-image",
                files={"image": ("ticket.jpg", io.BytesIO(_SMALL_JPEG), "image/jpeg")},
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 200
    assert "url" in response.json()
    assert response.json()["url"] == _FAKE_S3_URL


# PNG 형식 티켓 이미지 업로드 성공 테스트
@pytest.mark.asyncio
async def test_upload_ticket_image_png_success():
    token = await _get_token()
    png_url = "https://ticketdiary-images.s3.ap-northeast-2.amazonaws.com/ticket-images/test.png"

    with _s3_mock(png_url):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                "/api/v1/upload/ticket-image",
                files={"image": ("ticket.png", io.BytesIO(b"\x89PNG" + b"x" * 100), "image/png")},
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 200
    assert response.json()["url"] == png_url


# 지원하지 않는 이미지 형식 415 테스트
@pytest.mark.asyncio
async def test_upload_ticket_image_unsupported_format_415():
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/upload/ticket-image",
            files={"image": ("ticket.gif", io.BytesIO(b"GIF89a"), "image/gif")},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 415


# 파일 크기 초과 413 테스트 (Content-Length 헤더 기반 사전 거절)
@pytest.mark.asyncio
async def test_upload_ticket_image_too_large_413():
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/upload/ticket-image",
            files={"image": ("ticket.jpg", io.BytesIO(b"x" * (10 * 1024 * 1024 + 1)), "image/jpeg")},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 413


# 미인증 요청 401 테스트
@pytest.mark.asyncio
async def test_upload_ticket_image_no_auth_401():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/upload/ticket-image",
            files={"image": ("ticket.jpg", io.BytesIO(_SMALL_JPEG), "image/jpeg")},
        )

    assert response.status_code == 401


# 공연 사진 업로드 테스트

# 공연 사진 업로드 성공 테스트
@pytest.mark.asyncio
async def test_upload_concert_photo_success():
    token = await _get_token()
    photo_url = "https://ticketdiary-images.s3.ap-northeast-2.amazonaws.com/concert-photos/test.jpg"

    with _s3_mock(photo_url):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                "/api/v1/upload/concert-photo",
                files={"image": ("photo.jpg", io.BytesIO(_SMALL_JPEG), "image/jpeg")},
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 200
    assert response.json()["url"] == photo_url


# 지원하지 않는 형식 415 테스트
@pytest.mark.asyncio
async def test_upload_concert_photo_unsupported_format_415():
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/upload/concert-photo",
            files={"image": ("photo.bmp", io.BytesIO(b"BM"), "image/bmp")},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 415


# 미인증 요청 401 테스트
@pytest.mark.asyncio
async def test_upload_concert_photo_no_auth_401():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/upload/concert-photo",
            files={"image": ("photo.jpg", io.BytesIO(_SMALL_JPEG), "image/jpeg")},
        )

    assert response.status_code == 401


# S3 업로드 실패 502 테스트
@pytest.mark.asyncio
async def test_upload_ticket_image_s3_failure_502():
    from fastapi import HTTPException
    token = await _get_token()

    with patch("app.services.storage._do_upload", side_effect=HTTPException(status_code=502, detail="이미지 업로드에 실패했습니다.")):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                "/api/v1/upload/ticket-image",
                files={"image": ("ticket.jpg", io.BytesIO(_SMALL_JPEG), "image/jpeg")},
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 502
