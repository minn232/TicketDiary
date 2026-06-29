import uuid
from datetime import datetime, timezone
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi import HTTPException
from httpx import AsyncClient, ASGITransport

from app.main import app
from app.services.ocr import (
    _extract_raw_text,
    _parse_ticket_fields,
    _extract_title,
    _extract_concert_date,
    _extract_shipping_date,
    _extract_time,
    _extract_location,
    _extract_seat,
    _extract_platform,
    _extract_price,
    _extract_artist,
    _classify_event_type,
)
from conftest import kopis_mock


# 헬퍼

def _vision_response(text: str) -> dict:
    return {"responses": [{"fullTextAnnotation": {"text": text}}]}


def _httpx_post_mock(status_code: int = 200, json_body: dict | None = None):
    mock_response = MagicMock()
    mock_response.status_code = status_code
    mock_response.json.return_value = json_body or {}
    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.post = AsyncMock(return_value=mock_response)
    return patch("app.services.ocr.httpx.AsyncClient", return_value=mock_client)


def _ocr_mock(extracted: dict):
    return patch(
        "app.api.v1.endpoints.concerts.extract_ticket_info",
        new=AsyncMock(return_value=extracted),
    )


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


def _mock_concert(kopis_id: str = "PF_TEST_001", name: str = "테스트 공연", artist_name: list | None = None):
    c = MagicMock()
    c.id = uuid.uuid4()
    c.kopis_id = kopis_id
    c.name = name
    c.artist_name = artist_name if artist_name is not None else []
    c.venue = "잠실올림픽주경기장"
    c.start_date = datetime(2030, 6, 1, tzinfo=timezone.utc)
    c.end_date = datetime(2030, 6, 30, tzinfo=timezone.utc)
    c.genre = ["대중음악"]
    c.poster_url = None
    c.description = None
    c.price = None
    c.event_type = "SOLO"
    return c


_SAMPLE_EXTRACTED = {
    "title": "BTS World Tour",
    "date": "2030-06-01",
    "time": "18:00",
    "shipping_date": "2030-05-20",
    "location": "잠실올림픽주경기장",
    "seat": "R석 A구역 12열 15번",
    "platform": "INTERPARK",
    "price": 110000,
    "artist": ["BTS"],
    "event_type": "SOLO",
}

# 인터파크 스타일 티켓 OCR 샘플
_INTERPARK_TICKET = """인터파크 티켓
공연명 : BTS WORLD TOUR 2030
공연일시 : 2030.06.01 (토) 오후 6시
공연장소 : 잠실올림픽주경기장
좌석 : R석 A구역 12열 15번
결제금액 : 110,000원
발송예정일 : 2030.05.20"""

# YES24 스타일 티켓 OCR 샘플
_YES24_TICKET = """YES24
[아이유] 2030 콘서트
날짜 : 2030년 6월 1일
시간 : 18:00
장소 : KSPO돔
좌석 : VIP석 1구역 5열 20번
가격 : 150,000원
발송일 : 2030.05.15"""

# 레이블 없는 최소 샘플
_BARE_TICKET = """서머 페스티벌 2030
잠실올림픽주경기장
2030.06.01 오후6시
S석 B구역 3열 10번
88,000원"""


# _extract_raw_text 테스트

@pytest.mark.asyncio
async def test_extract_raw_text_success():
    with _httpx_post_mock(200, _vision_response("BTS 콘서트\n2030.06.01")):
        result = await _extract_raw_text(b"fake-image")
    assert result == "BTS 콘서트\n2030.06.01"


@pytest.mark.asyncio
async def test_extract_raw_text_vision_api_error():
    with _httpx_post_mock(status_code=500):
        with pytest.raises(HTTPException) as exc_info:
            await _extract_raw_text(b"fake-image")
    assert exc_info.value.status_code == 502


@pytest.mark.asyncio
async def test_extract_raw_text_no_text_detected():
    with _httpx_post_mock(200, {"responses": [{}]}):
        with pytest.raises(HTTPException) as exc_info:
            await _extract_raw_text(b"fake-image")
    assert exc_info.value.status_code == 422


# _parse_ticket_fields 테스트

def test_parse_ticket_fields_interpark_full():
    result = _parse_ticket_fields(_INTERPARK_TICKET)
    assert result["title"] == "BTS WORLD TOUR 2030"
    assert result["date"] == "2030-06-01"
    assert result["time"] == "18:00"
    assert result["shipping_date"] == "2030-05-20"
    assert result["location"] == "잠실올림픽주경기장"
    assert "R석" in result["seat"]
    assert result["platform"] == "INTERPARK"
    assert result["price"] == 110000
    assert result["event_type"] == "SOLO"


def test_parse_ticket_fields_yes24_full():
    result = _parse_ticket_fields(_YES24_TICKET)
    assert result["date"] == "2030-06-01"
    assert result["time"] == "18:00"
    assert result["shipping_date"] == "2030-05-15"
    assert "돔" in (result["location"] or "")
    assert "VIP석" in (result["seat"] or "")
    assert result["platform"] == "YES24"
    assert result["price"] == 150000


# 레이블 없는 최소 텍스트도 핵심 필드 추출
def test_parse_ticket_fields_bare_ticket():
    result = _parse_ticket_fields(_BARE_TICKET)
    assert result["date"] == "2030-06-01"
    assert result["time"] == "18:00"
    assert result["price"] == 88000
    assert result["event_type"] == "FESTIVAL"


# [아이유] 형식에서 아티스트 추출
def test_parse_ticket_fields_artist_from_bracket():
    result = _parse_ticket_fields(_YES24_TICKET)
    assert "아이유" in result["artist"]


# 인식 불가 필드는 None / 빈 리스트
def test_parse_ticket_fields_missing_fields_return_none():
    result = _parse_ticket_fields("공연 티켓")
    assert result["date"] is None
    assert result["time"] is None
    assert result["price"] is None
    assert result["artist"] == []


# 개별 파서 단위 테스트

def test_extract_title_label():
    assert _extract_title("공연명 : BTS WORLD TOUR") == "BTS WORLD TOUR"


def test_extract_title_fallback_first_line():
    result = _extract_title("BTS 콘서트\n2030.06.01\n잠실")
    assert result == "BTS 콘서트"


def test_extract_concert_date_label():
    assert _extract_concert_date("공연일시 : 2030.06.01") == "2030-06-01"


def test_extract_concert_date_korean_format():
    assert _extract_concert_date("날짜 : 2030년 6월 1일") == "2030-06-01"


def test_extract_concert_date_skips_shipping():
    text = "2030.07.15 공연\n발송예정일 : 2030.06.20"
    assert _extract_concert_date(text) == "2030-07-15"


def test_extract_shipping_date():
    assert _extract_shipping_date("발송예정일 : 2030.05.20") == "2030-05-20"
    assert _extract_shipping_date("배송일 : 2030년 5월 20일") == "2030-05-20"
    assert _extract_shipping_date("공연명 : 테스트") is None


def test_extract_time_afternoon():
    assert _extract_time("오후 6시") == "18:00"


def test_extract_time_hhmm():
    assert _extract_time("시간 : 18:00") == "18:00"


def test_extract_time_morning():
    assert _extract_time("오전 10시 30분") == "10:30"


def test_extract_location_label():
    assert _extract_location("공연장소 : 잠실올림픽주경기장") == "잠실올림픽주경기장"


def test_extract_location_keyword():
    result = _extract_location("KSPO돔에서 진행됩니다")
    assert result is not None and "돔" in result


def test_extract_seat_label():
    assert _extract_seat("좌석 : R석 A구역 12열 15번") == "R석 A구역 12열 15번"


def test_extract_seat_regex():
    result = _extract_seat("VIP석 1구역 5열")
    assert result is not None and "VIP석" in result


def test_extract_platform_interpark():
    assert _extract_platform("인터파크 티켓") == "INTERPARK"


def test_extract_platform_yes24():
    assert _extract_platform("YES24에서 구매") == "YES24"


def test_extract_platform_none():
    assert _extract_platform("공연 티켓") is None


def test_extract_price_with_comma():
    assert _extract_price("결제금액 : 110,000원") == 110000


def test_extract_price_no_comma():
    assert _extract_price("150000원") == 150000


def test_extract_price_noise_filtered():
    assert _extract_price("6원짜리 없음") is None


def test_extract_artist_label():
    assert _extract_artist("출연 : BTS, 세븐틴") == ["BTS", "세븐틴"]


def test_extract_artist_bracket():
    assert _extract_artist("[아이유] 콘서트") == ["아이유"]


def test_extract_artist_empty():
    assert _extract_artist("공연 티켓") == []


def test_classify_event_type_festival():
    assert _classify_event_type("서머 페스티벌 2030") == "FESTIVAL"
    assert _classify_event_type("Music Festival") == "FESTIVAL"


def test_classify_event_type_solo():
    assert _classify_event_type("BTS 단독 콘서트") == "SOLO"


# 개별 파서 추가 케이스

def test_extract_time_afternoon_colon():
    assert _extract_time("오후 8:00") == "20:00"
    assert _extract_time("오후 6:30") == "18:30"


def test_extract_time_morning_colon():
    assert _extract_time("오전 10:00") == "10:00"
    assert _extract_time("오전 9:30") == "09:30"


def test_extract_time_hhmm_bare():
    assert _extract_time("18:00") == "18:00"
    assert _extract_time("시간 : 20:30") == "20:30"


# 예매일시와 공연일시가 함께 있으면 공연일시만 추출
def test_extract_concert_date_ignores_booking_date():
    text = "예매일시 : 2025.03.10\n공연일시 : 2025.07.20"
    assert _extract_concert_date(text) == "2025-07-20"


def test_extract_concert_date_bare_ilsi():
    assert _extract_concert_date("일시 : 2030.06.01") == "2030-06-01"


def test_extract_platform_melon_variants():
    assert _extract_platform("ticket.melon.com에서 구매") == "멜론티켓"
    assert _extract_platform("melon 티켓 예매") == "멜론티켓"
    assert _extract_platform("멜론티켓") == "멜론티켓"


def test_extract_platform_nol():
    assert _extract_platform("NOL Ticket") == "NOL ticket"
    assert _extract_platform("nol 티켓") == "NOL ticket"


# 대괄호 안 요일 단일 글자는 아티스트로 추출하지 않음
def test_extract_artist_filters_weekday():
    assert _extract_artist("[토] 공연") == []
    assert _extract_artist("[일] 2030.06.01") == []


# ~님으로 이어지는 대괄호는 아티스트 후보에서 제외
def test_extract_artist_filters_customer_name():
    result = _extract_artist("[홍길동]님 안녕하세요")
    assert "홍길동" not in result


def test_extract_artist_bracket_still_works():
    assert _extract_artist("[아이유] 2030 콘서트") == ["아이유"]
    assert _extract_artist("[BTS] WORLD TOUR") == ["BTS"]


# 예매·예약으로 시작하는 줄은 제목 후보에서 제외
def test_extract_title_skips_booking_labels():
    text = "예매번호 : 12345\n예약자 : 홍길동\nBTS 콘서트"
    assert _extract_title(text) == "BTS 콘서트"


# /scan 엔드포인트 통합 테스트

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


@pytest.mark.asyncio
async def test_scan_image_too_large(get_auth_token):
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/concerts/scan",
            files={"image": ("ticket.jpg", b"x" * (10 * 1024 * 1024 + 1), "image/jpeg")},
            headers={"Authorization": f"Bearer {get_auth_token}"},
        )

    assert response.status_code == 413


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


@pytest.mark.asyncio
async def test_scan_unauthorized():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            "/api/v1/concerts/scan",
            files={"image": ("ticket.jpg", b"fake-image", "image/jpeg")},
        )

    assert response.status_code == 401


# KOPIS artist 크로스체크 테스트

# DB에 캐시된 artist_name이 있는 후보에서 추출 결과 보완
@pytest.mark.asyncio
async def test_scan_artist_backfilled_from_db(get_auth_token):
    extracted_no_artist = {**_SAMPLE_EXTRACTED, "artist": []}
    candidate = _mock_concert(artist_name=["아이유"])

    with (
        _ocr_mock(extracted_no_artist),
        patch("app.api.v1.endpoints.concerts.kopis_search", new=AsyncMock(return_value=[candidate])),
    ):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                "/api/v1/concerts/scan",
                files={"image": ("ticket.jpg", b"fake-image", "image/jpeg")},
                headers={"Authorization": f"Bearer {get_auth_token}"},
            )

    assert response.status_code == 200
    assert response.json()["extracted"]["artist"] == ["아이유"]


# 후보 1개이고 DB에 artist 없으면 상세 API로 보완, candidates도 갱신
@pytest.mark.asyncio
async def test_scan_artist_fetched_from_detail_api(get_auth_token):
    extracted_no_artist = {**_SAMPLE_EXTRACTED, "artist": []}
    candidate = _mock_concert(kopis_id="PF_B_001", artist_name=[])
    detail = _mock_concert(kopis_id="PF_B_001", artist_name=["BTS"])

    with (
        _ocr_mock(extracted_no_artist),
        patch("app.api.v1.endpoints.concerts.kopis_search", new=AsyncMock(return_value=[candidate])),
        patch("app.api.v1.endpoints.concerts.get_concert_detail", new=AsyncMock(return_value=detail)),
    ):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                "/api/v1/concerts/scan",
                files={"image": ("ticket.jpg", b"fake-image", "image/jpeg")},
                headers={"Authorization": f"Bearer {get_auth_token}"},
            )

    data = response.json()
    assert data["extracted"]["artist"] == ["BTS"]
    assert data["candidates"][0]["artist_name"] == ["BTS"]


# 후보가 여러 개이면 상세 API 호출 없이 artist 빈 채로 반환
@pytest.mark.asyncio
async def test_scan_no_detail_call_when_multiple_candidates(get_auth_token):
    extracted_no_artist = {**_SAMPLE_EXTRACTED, "artist": []}
    candidates = [
        _mock_concert(kopis_id="PF_M_001", artist_name=[]),
        _mock_concert(kopis_id="PF_M_002", artist_name=[]),
    ]

    with (
        _ocr_mock(extracted_no_artist),
        patch("app.api.v1.endpoints.concerts.kopis_search", new=AsyncMock(return_value=candidates)),
        patch("app.api.v1.endpoints.concerts.get_concert_detail") as mock_detail,
    ):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                "/api/v1/concerts/scan",
                files={"image": ("ticket.jpg", b"fake-image", "image/jpeg")},
                headers={"Authorization": f"Bearer {get_auth_token}"},
            )

    assert response.status_code == 200
    assert response.json()["extracted"]["artist"] == []
    mock_detail.assert_not_called()


# OCR 아티스트 추출 성공 시 크로스체크 건너뜀
@pytest.mark.asyncio
async def test_scan_artist_not_overridden_when_ocr_extracted(get_auth_token):
    extracted_with_artist = {**_SAMPLE_EXTRACTED, "artist": ["세븐틴"]}
    candidate = _mock_concert(artist_name=["BTS"])

    with (
        _ocr_mock(extracted_with_artist),
        patch("app.api.v1.endpoints.concerts.kopis_search", new=AsyncMock(return_value=[candidate])),
        patch("app.api.v1.endpoints.concerts.get_concert_detail") as mock_detail,
    ):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                "/api/v1/concerts/scan",
                files={"image": ("ticket.jpg", b"fake-image", "image/jpeg")},
                headers={"Authorization": f"Bearer {get_auth_token}"},
            )

    assert response.json()["extracted"]["artist"] == ["세븐틴"]
    mock_detail.assert_not_called()
