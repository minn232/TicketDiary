import base64

import httpx
import pytest

from app.core.config import settings


# KOPIS API 키 확인 (실제 요청)

# KOPIS API 키로 공연 목록 조회 시 정상 응답 테스트
@pytest.mark.asyncio
async def test_kopis_api_key_valid():
    async with httpx.AsyncClient() as client:
        response = await client.get(
            f"{settings.KOPIS_BASE_URL}/pblprfr",
            params={
                "service": settings.KOPIS_API_KEY,
                "stdate": "20300101",
                "eddate": "20300101",
                "rows": 1,
                "cpage": 1,
                "prfstate": "01",
            },
        )

    assert response.status_code == 200, f"KOPIS 응답 오류: {response.status_code}"
    assert b"<dbs" in response.content, "KOPIS 응답 형식이 올바르지 않습니다"


# Setlist.fm API 키 확인

# Setlist.fm API 키로 셋리스트 검색 시 정상 응답 테스트 (401/403이 아닌지 확인)
@pytest.mark.asyncio
async def test_setlistfm_api_key_valid():
    async with httpx.AsyncClient() as client:
        response = await client.get(
            f"{settings.SETLISTFM_BASE_URL}/search/setlists",
            params={"artistName": "BTS", "p": 1},
            headers={
                "x-api-key": settings.SETLISTFM_API_KEY,
                "Accept": "application/json",
            },
        )

    assert response.status_code != 401, "Setlist.fm API 키가 유효하지 않습니다 (401)"
    assert response.status_code != 403, "Setlist.fm API 키가 거부되었습니다 (403)"
    assert response.status_code in (200, 404), f"예상치 못한 응답: {response.status_code}"


# Google Vision API 키 확인

# Google Vision API 키로 1x1 흰색 픽셀 이미지 분석 요청 시 정상 응답 테스트
@pytest.mark.asyncio
async def test_google_vision_api_key_valid():
    # 1x1 흰색 픽셀 PNG (최소 이미지)
    tiny_png = (
        b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01"
        b"\x08\x02\x00\x00\x00\x90wS\xde\x00\x00\x00\x0cIDATx\x9cc\xf8\x0f\x00"
        b"\x00\x01\x01\x00\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82"
    )
    image_b64 = base64.b64encode(tiny_png).decode()

    async with httpx.AsyncClient() as client:
        response = await client.post(
            f"https://vision.googleapis.com/v1/images:annotate?key={settings.GOOGLE_VISION_API_KEY}",
            json={
                "requests": [{
                    "image": {"content": image_b64},
                    "features": [{"type": "TEXT_DETECTION", "maxResults": 1}],
                }]
            },
        )

    assert response.status_code != 400 or "API_KEY_INVALID" not in response.text, \
        "Google Vision API 키가 유효하지 않습니다"
    assert response.status_code == 200, f"Google Vision 응답 오류: {response.status_code} - {response.text}"
