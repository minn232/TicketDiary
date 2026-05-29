from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi import HTTPException
from httpx import AsyncClient, ASGITransport

from app.main import app
from app.services.ocr import _extract_raw_text, _parse_ticket_fields
from conftest import kopis_mock


# 헬퍼

# Google Vision API 응답 형식 생성
def _vision_response(text: str) -> dict:
    return {"responses": [{"fullTextAnnotation": {"text": text}}]}


# ocr.py의 httpx.AsyncClient.post 모킹
def _httpx_post_mock(status_code: int = 200, json_body: dict | None = None):
    mock_response = MagicMock()
    mock_response.status_code = status_code
    mock_response.json.return_value = json_body or {}
    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.post = AsyncMock(return_value=mock_response)
    return patch("app.services.ocr.httpx.AsyncClient", return_value=mock_client)


# extract_ticket_info 전체 모킹 (Vision + LLM 호출 생략)
def _ocr_mock(extracted: dict):
    return patch(
        "app.api.v1.endpoints.concerts.extract_ticket_info",
        new=AsyncMock(return_value=extracted),
    )


# KOPIS 가짜 XML 생성
def _make_kopis_xml(kopis_id: str, name: str) -> bytes:
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f"<dbs><db>"
        f"<mt20id>{kopis_id}</mt20id>"
        f"<prfnm>{name}</prfnm>"
        f"<prfpdfrom>2030.06.01</prfpdfrom>"
        f"<prfpdto>2030.06.30</prfpdto>"
        f"<fcltynm>잠실올림픽주경기장</fcltynm>"
        f"<genrenm>대중음악</genrenm>"
        f"</db></dbs>"
    ).encode("utf-8")


# 샘플 LLM 추출 결과
_SAMPLE_EXTRACTED = {
    "title": "BTS World Tour",
    "date": "2030-06-01",
    "time": "18:00",
    "shipping_date": "2030-05-20",
    "location": "잠실올림픽주경기장",
    "seat": "R석 A구역 12열 15번",
    "platform": "인터파크",
    "price": 110000,
    "artist": ["BTS"],
    "event_type": "SOLO",
}


# _extract_raw_text 단위 테스트

# Google Vision API 텍스트 추출 성공 테스트
@pytest.mark.asyncio
async def test_extract_raw_text_success():
    with _httpx_post_mock(200, _vision_response("BTS 콘서트\n2030.06.01")):
        result = await _extract_raw_text(b"fake-image")

    assert result == "BTS 콘서트\n2030.06.01"


# Vision API 오류 시 502 반환 테스트
@pytest.mark.asyncio
async def test_extract_raw_text_vision_api_error():
    with _httpx_post_mock(status_code=500):
        with pytest.raises(HTTPException) as exc_info:
            await _extract_raw_text(b"fake-image")

    assert exc_info.value.status_code == 502


# 이미지에서 텍스트 인식 불가 시 422 반환 테스트
@pytest.mark.asyncio
async def test_extract_raw_text_no_text_detected():
    with _httpx_post_mock(200, {"responses": [{}]}):
        with pytest.raises(HTTPException) as exc_info:
            await _extract_raw_text(b"fake-image")

    assert exc_info.value.status_code == 422


# _parse_ticket_fields 단위 테스트

# LLM 팀 응답 정상 파싱 테스트
@pytest.mark.asyncio
async def test_parse_ticket_fields_success():
    with _httpx_post_mock(200, _SAMPLE_EXTRACTED):
        result = await _parse_ticket_fields("BTS 콘서트\n2030.06.01")

    assert result["title"] == "BTS World Tour"
    assert result["date"] == "2030-06-01"
    assert result["time"] == "18:00"
    assert result["artist"] == ["BTS"]
    assert result["price"] == 110000
    assert result["event_type"] == "SOLO"


# LLM 팀 오류 시 502 반환 테스트
@pytest.mark.asyncio
async def test_parse_ticket_fields_llm_error():
    with _httpx_post_mock(status_code=500):
        with pytest.raises(HTTPException) as exc_info:
            await _parse_ticket_fields("some text")

    assert exc_info.value.status_code == 502


# artist null 응답 시 빈 배열 반환 테스트
@pytest.mark.asyncio
async def test_parse_ticket_fields_artist_null_defaults_to_empty_list():
    with _httpx_post_mock(200, {**_SAMPLE_EXTRACTED, "artist": None}):
        result = await _parse_ticket_fields("some text")

    assert result["artist"] == []


# LLM이 일부 필드만 반환해도 나머지는 None으로 처리 테스트
@pytest.mark.asyncio
async def test_parse_ticket_fields_partial_response():
    with _httpx_post_mock(200, {"title": "서머 페스티벌", "event_type": "FESTIVAL"}):
        result = await _parse_ticket_fields("some text")

    assert result["title"] == "서머 페스티벌"
    assert result["event_type"] == "FESTIVAL"
    assert result["date"] is None
    assert result["price"] is None
    assert result["artist"] == []


# /scan 엔드포인트 통합 테스트

# 정상 스캔 + KOPIS 후보 반환 테스트
@pytest.mark.asyncio
async def test_scan_success_with_kopis_candidates(get_auth_token):
    with _ocr_mock(_SAMPLE_EXTRACTED), kopis_mock(_make_kopis_xml("PF_OCR_001", "BTS World Tour")):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                "/api/v1/concerts/scan",
                files={"image": ("ticket.jpg", b"fake-image", "image/jpeg")},
                headers={"Authorization": f"Bearer {get_auth_token}"},
            )

    assert response.status_code == 200
    data = response.json()
    assert data["extracted"]["title"] == "BTS World Tour"
    assert data["extracted"]["artist"] == ["BTS"]
    assert data["extracted"]["event_type"] == "SOLO"
    assert data["extracted"]["price"] == 110000
    assert data["extracted"]["seat"] == "R석 A구역 12열 15번"
    assert len(data["candidates"]) == 1
    assert data["candidates"][0]["kopis_id"] == "PF_OCR_001"


# artist 없을 때 title로 KOPIS 검색 테스트
@pytest.mark.asyncio
async def test_scan_title_fallback_when_no_artist(get_auth_token):
    extracted = {**_SAMPLE_EXTRACTED, "artist": [], "title": "BTS World Tour"}
    with _ocr_mock(extracted), kopis_mock(_make_kopis_xml("PF_OCR_002", "BTS World Tour")):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                "/api/v1/concerts/scan",
                files={"image": ("ticket.jpg", b"fake-image", "image/jpeg")},
                headers={"Authorization": f"Bearer {get_auth_token}"},
            )

    assert response.status_code == 200
    assert len(response.json()["candidates"]) == 1


# artist도 title도 없으면 KOPIS 검색 생략 테스트
@pytest.mark.asyncio
async def test_scan_no_candidates_when_no_keyword(get_auth_token):
    extracted = {**_SAMPLE_EXTRACTED, "artist": [], "title": None}
    with _ocr_mock(extracted):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                "/api/v1/concerts/scan",
                files={"image": ("ticket.jpg", b"fake-image", "image/jpeg")},
                headers={"Authorization": f"Bearer {get_auth_token}"},
            )

    assert response.status_code == 200
    assert response.json()["candidates"] == []


# FESTIVAL event_type 정상 반환 테스트
@pytest.mark.asyncio
async def test_scan_festival_event_type(get_auth_token):
    extracted = {**_SAMPLE_EXTRACTED, "event_type": "FESTIVAL", "artist": ["아티스트A", "아티스트B"]}
    with _ocr_mock(extracted), kopis_mock(_make_kopis_xml("PF_OCR_FEST", "서머 페스티벌")):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                "/api/v1/concerts/scan",
                files={"image": ("ticket.jpg", b"fake-image", "image/jpeg")},
                headers={"Authorization": f"Bearer {get_auth_token}"},
            )

    assert response.status_code == 200
    assert response.json()["extracted"]["event_type"] == "FESTIVAL"


# KOPIS 오류 시 후보 없이 추출 정보만 반환 테스트
@pytest.mark.asyncio
async def test_scan_kopis_error_returns_empty_candidates(get_auth_token):
    with _ocr_mock(_SAMPLE_EXTRACTED), kopis_mock(b"", status_code=500):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                "/api/v1/concerts/scan",
                files={"image": ("ticket.jpg", b"fake-image", "image/jpeg")},
                headers={"Authorization": f"Bearer {get_auth_token}"},
            )

    assert response.status_code == 200
    assert response.json()["candidates"] == []


# 이미지 크기 초과 시 413 반환 테스트
@pytest.mark.asyncio
async def test_scan_image_too_large(get_auth_token):
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/concerts/scan",
            files={"image": ("ticket.jpg", b"x" * (10 * 1024 * 1024 + 1), "image/jpeg")},
            headers={"Authorization": f"Bearer {get_auth_token}"},
        )

    assert response.status_code == 413


# OCR 서비스 오류 시 502 반환 테스트
@pytest.mark.asyncio
async def test_scan_ocr_service_error(get_auth_token):
    with patch(
        "app.api.v1.endpoints.concerts.extract_ticket_info",
        new=AsyncMock(side_effect=HTTPException(status_code=502)),
    ):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                "/api/v1/concerts/scan",
                files={"image": ("ticket.jpg", b"fake-image", "image/jpeg")},
                headers={"Authorization": f"Bearer {get_auth_token}"},
            )

    assert response.status_code == 502


# 미인증 요청 401 반환 테스트
@pytest.mark.asyncio
async def test_scan_unauthorized():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/concerts/scan",
            files={"image": ("ticket.jpg", b"fake-image", "image/jpeg")},
        )

    assert response.status_code == 401
