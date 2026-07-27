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
    _extract_title_candidates,
    _extract_concert_date,
    _extract_shipping_date,
    _extract_time,
    _extract_location,
    _extract_seat,
    _extract_platform,
    _extract_price,
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


# 인식 불가 필드는 None
def test_parse_ticket_fields_missing_fields_return_none():
    result = _parse_ticket_fields("공연 티켓")
    assert result["date"] is None
    assert result["time"] is None
    assert result["price"] is None


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


# 등급명 바로 앞 글자가 공백 없이 붙어있어도(예: 줄바꿈 없이 이어진 라벨) 그 글자까지
# 등급명으로 잘못 끌려들어가지 않는지 테스트 ("아지정석"처럼 엉뚱하게 나오던 버그)
def test_extract_seat_does_not_bleed_preceding_character():
    assert _extract_seat("공연장 안내사항\n지정석 A구역 3열") == "지정석 A구역 3열"


def test_extract_seat_regex_no_space_before_grade():
    # 앞 단어와 등급명 사이에 공백이 전혀 없는 경우(예: 라벨 없이 값만 붙어 인쇄된 경우)
    assert _extract_seat("가나다라마아지정석") is None


# "좌석"은 등급명이 아니라 일반 단어이므로("좌석 안내" 등) 매칭에서 건너뛰고 실제 등급을 찾는지 테스트
def test_extract_seat_skips_generic_seat_word():
    assert _extract_seat("좌석 안내\nR석 A구역 12열") == "R석 A구역 12열"


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


# 예매·예약으로 시작하는 줄은 제목 후보에서 제외
def test_extract_title_skips_booking_labels():
    text = "예매번호 : 12345\n예약자 : 홍길동\nBTS 콘서트"
    assert _extract_title(text) == "BTS 콘서트"


# 인터파크/NOL 로고 텍스트만 있는 줄은 공연명이 아니므로 제외
def test_extract_title_skips_platform_brand_line():
    assert _extract_title("INTERPARK\nBTS 콘서트\n2030.06.01") == "BTS 콘서트"
    assert _extract_title("NOL Ticket\nBTS 콘서트") == "BTS 콘서트"


# 전화번호 라벨 줄은 공연명이 아니므로 제외
def test_extract_title_skips_phone_number_line():
    text = "전화번호 : 010-1234-5678\nBTS 콘서트"
    assert _extract_title(text) == "BTS 콘서트"


# 금액/결제/수량 라벨 줄은 공연명이 아니므로 제외
def test_extract_title_skips_amount_line():
    text = "금액: 110,000원 (일반)\nBTS 콘서트"
    assert _extract_title(text) == "BTS 콘서트"


# 판매일자/구매일자/발권일자 라벨 줄은 공연명이 아니므로 제외
def test_extract_title_skips_sale_date_line():
    text = "판매일자: 2025-08-07\nBTS 콘서트"
    assert _extract_title(text) == "BTS 콘서트"


# "2024 HA HYUN SANG CONCERT"처럼 연도로 시작하는 줄은 숫자-스킵 규칙에 걸리지 않고 제목으로 채택
def test_extract_title_allows_year_prefixed_line():
    assert _extract_title("2025 렛츠락 페스티벌\n일시: 2025년 09월 06일") == "2025 렛츠락 페스티벌"
    assert _extract_title("2024 HA HYUN SANG CONCERT\n일시: 2024년 12월 01일") == "2024 HA HYUN SANG CONCERT"


# 연도로 시작하지 않는 숫자 줄(예매번호/좌석코드 등)은 계속 제외되는지 확인 (회귀 방지)
def test_extract_title_still_skips_non_year_digit_lines():
    text = "20241201(2)\n2층 41구역 54번\nBTS 콘서트"
    assert _extract_title(text) == "BTS 콘서트"


# 제목 후보 목록은 첫 줄이 실제로는 부제였을 때를 대비해 뒤쪽의 다른 유효 줄도 순서대로 포함해야 함
def test_extract_title_candidates_includes_later_lines():
    text = "빨래는 오늘을 살아가는\n우리들의 이야기다\nR석\nMUSICAL\n빨래"
    candidates = _extract_title_candidates(text)
    assert candidates[0] == "빨래는 오늘을 살아가는"
    assert "빨래" in candidates
    assert "우리들의 이야기다" in candidates


# 라벨(공연명:)이 있으면 그 값이 맨 앞 후보로 오고, 이어서 본문의 다른 후보 줄도 포함
def test_extract_title_candidates_label_first():
    text = "공연명 : BTS WORLD TOUR\n부제: Encore\nR석"
    candidates = _extract_title_candidates(text)
    assert candidates[0] == "BTS WORLD TOUR"


# 라벨 없이 좌석 등급만 단독으로 적힌 줄(비지정석 등)은 공연명이 아니므로 제외
def test_extract_title_skips_bare_seat_grade_line():
    assert _extract_title("비지정석\nBTS 콘서트") == "BTS 콘서트"
    assert _extract_title("VIP석\nBTS 콘서트") == "BTS 콘서트"


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
    assert data["extracted"]["event_type"] == "SOLO"
    assert data["extracted"]["price"] == 110000
    assert data["extracted"]["seat"] == "R석 A구역 12열 15번"
    assert len(data["candidates"]) == 1
    assert data["candidates"][0]["kopis_id"] == "PF_OCR_001"


# 유저당 시간당 요청 상한 초과 시 429 테스트 (Vision/LLM 호출 비용 남용 방지)
@pytest.mark.asyncio
async def test_scan_rate_limited_after_10_calls_per_hour(get_auth_token):
    headers = {"Authorization": f"Bearer {get_auth_token}"}
    statuses = []
    with _ocr_mock(_SAMPLE_EXTRACTED), kopis_mock(_make_kopis_xml("PF_OCR_RATE", "테스트 공연")):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            for _ in range(11):
                response = await ac.post(
                    "/api/v1/concerts/scan",
                    files={"image": ("ticket.jpg", b"fake-image", "image/jpeg")},
                    headers=headers,
                )
                statuses.append(response.status_code)

    assert statuses[:10] == [200] * 10
    assert statuses[10] == 429


# title 후보 중 앞쪽이 날짜가 안 맞는 흔한 구절로 결과를 내면 건너뛰고,
# 날짜가 실제로 겹치는 뒤쪽 후보(title_candidates)를 채택하는지 테스트
# (예: "우리들의 이야기다"는 무관한 공연을 걸지만 날짜가 안 맞음 -> "빨래"로 재시도해 정확한 결과를 얻음)
@pytest.mark.asyncio
async def test_scan_uses_confident_later_candidate(get_auth_token):
    extracted = {
        **_SAMPLE_EXTRACTED,
        "title": "우리들의 이야기다",
        "title_candidates": ["우리들의 이야기다", "빨래"],
        "date": "2024-07-17",
        "location": None,  # 이 테스트는 날짜 확신 로직만 검증 (장소 교차검증과 무관하게)
    }

    def _xml(kopis_id, name, start, end):
        return (
            f'<?xml version="1.0" encoding="UTF-8"?><dbs><db>'
            f"<mt20id>{kopis_id}</mt20id><prfnm>{name}</prfnm>"
            f"<prfpdfrom>{start}</prfpdfrom><prfpdto>{end}</prfpdto>"
            f"<fcltynm>테스트공연장</fcltynm><genrenm>대중음악</genrenm>"
            f"</db></dbs>"
        ).encode("utf-8")

    unconfident_xml = _xml("PF_WRONG_001", "우리들의 학창시절", "2024.09.14", "2024.09.14")
    confident_xml = _xml("PF_RIGHT_001", "빨래 [대학로]", "2024.06.07", "2025.03.02")

    async def _mock_get(url, params=None, **kwargs):
        keyword = (params or {}).get("shprfnm", "")
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.content = confident_xml if keyword.strip() == "빨래" else unconfident_xml
        return mock_response

    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = _mock_get

    with (
        _ocr_mock(extracted),
        patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client),
    ):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                "/api/v1/concerts/scan",
                files={"image": ("ticket.jpg", b"fake-image", "image/jpeg")},
                headers={"Authorization": f"Bearer {get_auth_token}"},
            )

    assert response.status_code == 200
    data = response.json()
    assert len(data["candidates"]) == 1
    assert data["candidates"][0]["kopis_id"] == "PF_RIGHT_001"


# title 후보를 전부 시도해도 확신 가능한 결과가 없으면 공연장+날짜 검색으로 대체하는지 테스트
# (제목이 KOPIS 등록명과 완전히 어긋나는 케이스의 최후 수단)
@pytest.mark.asyncio
async def test_scan_falls_back_to_venue_search(get_auth_token):
    extracted = {
        **_SAMPLE_EXTRACTED,
        "title": "전혀 다른 제목",
        "title_candidates": ["전혀 다른 제목"],
        "date": "2024-07-17",
        "location": "인터파크 유니플렉스 2관",
    }

    facility_xml = (
        '<?xml version="1.0" encoding="UTF-8"?><dbs>'
        '<db><fcltynm>유니플렉스</fcltynm><mt10id>FC001233</mt10id></db>'
        '</dbs>'
    ).encode("utf-8")
    venue_performance_xml = (
        '<?xml version="1.0" encoding="UTF-8"?><dbs><db>'
        "<mt20id>PF_BYVENUE_001</mt20id><prfnm>빨래 [대학로]</prfnm>"
        "<prfpdfrom>2024.06.07</prfpdfrom><prfpdto>2025.03.02</prfpdto>"
        "<fcltynm>유니플렉스</fcltynm><genrenm>대중음악</genrenm>"
        "</db></dbs>"
    ).encode("utf-8")

    async def _mock_get(url, params=None, **kwargs):
        mock_response = MagicMock()
        mock_response.status_code = 200
        if url.endswith("/prfplc"):
            mock_response.content = facility_xml
        elif (params or {}).get("prfplccd"):
            mock_response.content = venue_performance_xml
        else:
            mock_response.content = b'<?xml version="1.0" encoding="UTF-8"?><dbs/>'
        return mock_response

    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = _mock_get

    with (
        _ocr_mock(extracted),
        patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client),
    ):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                "/api/v1/concerts/scan",
                files={"image": ("ticket.jpg", b"fake-image", "image/jpeg")},
                headers={"Authorization": f"Bearer {get_auth_token}"},
            )

    assert response.status_code == 200
    data = response.json()
    assert len(data["candidates"]) == 1
    assert data["candidates"][0]["kopis_id"] == "PF_BYVENUE_001"


# 제목 후보와 장소 검색 모두 확신 가능한(날짜 일치) 결과를 못 찾으면, 날짜가 안 맞는 무관한 결과를
# 성공으로 오인해 반환하지 않고 빈 후보 목록을 반환하는지 테스트
# (예: "스탠딩"이 "스탠딩에그"에 우연히 부분일치해도 날짜가 다르면 그 결과를 쓰지 않아야 함)
@pytest.mark.asyncio
async def test_scan_returns_empty_when_no_confident_match(get_auth_token):
    extracted = {
        **_SAMPLE_EXTRACTED,
        "title": "REJOICE ASIA TOUR 2024",
        "title_candidates": ["REJOICE ASIA TOUR 2024", "스탠딩"],
        "date": "2024-11-30",
        "location": "일산 킨텍스 제1전시장 5홀",
    }

    # "스탠딩"만 날짜가 전혀 다른 무관한 공연을 반환, 나머지(및 장소 검색)는 전부 빈 결과
    unrelated_xml = (
        '<?xml version="1.0" encoding="UTF-8"?><dbs><db>'
        "<mt20id>PF_UNRELATED_001</mt20id><prfnm>스탠딩에그 콘서트</prfnm>"
        "<prfpdfrom>2024.12.14</prfpdfrom><prfpdto>2024.12.14</prfpdto>"
        "<fcltynm>테스트공연장</fcltynm><genrenm>대중음악</genrenm>"
        "</db></dbs>"
    ).encode("utf-8")
    empty_xml = b'<?xml version="1.0" encoding="UTF-8"?><dbs/>'
    empty_facility_xml = b'<?xml version="1.0" encoding="UTF-8"?><dbs/>'

    async def _mock_get(url, params=None, **kwargs):
        mock_response = MagicMock()
        mock_response.status_code = 200
        if url.endswith("/prfplc"):
            mock_response.content = empty_facility_xml
        elif (params or {}).get("shprfnm", "").strip() == "스탠딩":
            mock_response.content = unrelated_xml
        else:
            mock_response.content = empty_xml
        return mock_response

    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = _mock_get

    with (
        _ocr_mock(extracted),
        patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client),
    ):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                "/api/v1/concerts/scan",
                files={"image": ("ticket.jpg", b"fake-image", "image/jpeg")},
                headers={"Authorization": f"Bearer {get_auth_token}"},
            )

    assert response.status_code == 200
    assert response.json()["candidates"] == []


@pytest.mark.asyncio
async def test_scan_no_candidates_when_no_keyword(get_auth_token):
    extracted = {**_SAMPLE_EXTRACTED, "title": None}
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
    extracted = {**_SAMPLE_EXTRACTED, "event_type": "FESTIVAL"}
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
