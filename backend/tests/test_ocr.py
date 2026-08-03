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
    extract_ticket_info,
    _group_rows,
    _extract_fields_from_rows,
    _extract_title_from_layout,
    _parse_ticket_fields_from_layout,
    _paragraph_text,
    _flatten_paragraphs,
    _strip_trailing_ellipsis,
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


# 예매내역 캡처 레이아웃 파싱 테스트용 - Vision 응답의 words/symbols 계층을 직접 만들지
# 않고, 문단(paragraph) 텍스트 + bbox만으로 annotation을 구성하는 헬퍼.
# 실제 Vision은 단어 사이 진짜 공백일 때만 detectedBreak=SPACE를 붙이므로(그 외엔
# 시각적 줄바꿈으로 취급돼 공백이 안 들어감 - _paragraph_text 참고), 여기서도 각 단어
# 끝에 SPACE break를 명시해야 재구성 시 원래 텍스트대로 공백이 살아남는다
def _paragraph(text: str, x0: int, y0: int, x1: int, y1: int) -> dict:
    words = text.split(" ")
    word_objs = []
    for i, word in enumerate(words):
        symbols = [{"text": ch} for ch in word]
        if i < len(words) - 1 and symbols:
            symbols[-1]["property"] = {"detectedBreak": {"type": "SPACE"}}
        word_objs.append({"symbols": symbols})
    return {
        "words": word_objs,
        "boundingBox": {"vertices": [
            {"x": x0, "y": y0}, {"x": x1, "y": y0}, {"x": x1, "y": y1}, {"x": x0, "y": y1},
        ]},
    }


def _annotation(paragraphs: list[dict], full_text: str) -> dict:
    return {
        "fullTextAnnotation": {
            "text": full_text,
            "pages": [{"blocks": [{"paragraphs": paragraphs}]}],
        }
    }


# 실샘플(이미지1, 티켓링크 추정)과 같은 구조: 헤더 제목 + "라벨(왼쪽)/값(오른쪽)" 격자 3행
_BOOKING_HISTORY_PARAGRAPHS = [
    _paragraph("상세내역", 40, 40, 200, 70),
    _paragraph("YUURI ARENA LIVE 2025 at SEOUL", 40, 100, 600, 140),
    _paragraph("관람일시", 40, 300, 160, 320),
    _paragraph("2025.05.04(일) 17:00", 300, 300, 560, 320),
    _paragraph("장소", 40, 340, 160, 360),
    _paragraph("KSPO DOME", 300, 340, 500, 360),
    _paragraph("예매채널", 40, 380, 160, 400),
    _paragraph("티켓링크웹", 300, 380, 480, 400),
]
_BOOKING_HISTORY_FULL_TEXT = (
    "상세내역\nYUURI ARENA LIVE 2025 at SEOUL\n관람일시\n2025.05.04(일) 17:00\n"
    "장소\nKSPO DOME\n예매채널\n티켓링크웹"
)


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


# 예매내역 캡처 레이아웃(좌표 기반 격자) 파싱 테스트

# 실제 Vision API 응답으로 검증됨: "관람일시"처럼 공백 없는 한글 라벨도 시각적 줄바꿈
# 때문에 별도 word로 쪼개져서 오는데, 그 사이 break가 LINE_BREAK(진짜 공백 아님)이면
# 공백을 넣으면 안 됨 - 넣으면 "관람일 시"가 돼서 라벨 사전과 안 맞아 격자 인식 자체가
# 실패하는 회귀가 있었음(실사용 이미지로 직접 재현 후 수정)
def test_paragraph_text_no_space_on_line_break():
    paragraph = {
        "words": [
            {"symbols": [
                {"text": "관"}, {"text": "람"},
                {"text": "일", "property": {"detectedBreak": {"type": "LINE_BREAK"}}},
            ]},
            {"symbols": [{"text": "시"}]},
        ]
    }
    assert _paragraph_text(paragraph) == "관람일시"


# 진짜 공백(SPACE)일 때는 정상적으로 공백이 들어가는지 확인 (위 테스트와의 대조)
def test_paragraph_text_inserts_space_on_space_break():
    paragraph = {
        "words": [
            {"symbols": [
                {"text": "K"}, {"text": "S"}, {"text": "P"},
                {"text": "O", "property": {"detectedBreak": {"type": "SPACE"}}},
            ]},
            {"symbols": [{"text": "D"}, {"text": "O"}, {"text": "M"}, {"text": "E"}]},
        ]
    }
    assert _paragraph_text(paragraph) == "KSPO DOME"


def _word_with_bbox(text: str, x0: int, y0: int, x1: int, y1: int) -> dict:
    return {
        "symbols": [{"text": ch} for ch in text],
        "boundingBox": {"vertices": [
            {"x": x0, "y": y0}, {"x": x1, "y": y0}, {"x": x1, "y": y1}, {"x": x0, "y": y1},
        ]},
    }


# 실사용 캡처(멜론)로 확인된 회귀: Vision이 관람일/장소/매수처럼 서로 다른 값을 담은
# 여러 줄을 하나의 문단으로 합쳐서 반환하는 경우, 그 문단의 word bbox를 다시 Y좌표로
# 재클러스터링해서 줄 단위로 쪼개는지 확인
def test_flatten_paragraphs_splits_merged_multiline_paragraph():
    merged_paragraph = {
        "words": [
            _word_with_bbox("2026.03.14", 550, 700, 750, 735),
            _word_with_bbox("1매", 550, 820, 590, 855),
        ],
        "boundingBox": {"vertices": [
            {"x": 550, "y": 700}, {"x": 750, "y": 700}, {"x": 750, "y": 855}, {"x": 550, "y": 855},
        ]},
    }
    annotation = _annotation([merged_paragraph], "2026.03.14\n1매")
    blocks = _flatten_paragraphs(annotation)
    assert [b["text"] for b in blocks] == ["2026.03.14", "1매"]


# 한 줄짜리 정상 문단은 (단어 높이 대비 문단 높이가 크지 않으므로) 쪼개지지 않아야 함
def test_flatten_paragraphs_does_not_split_single_line_paragraph():
    words = [
        _word_with_bbox("KSPO", 300, 340, 400, 360),
        _word_with_bbox("DOME", 410, 341, 500, 361),
    ]
    words[0]["symbols"][-1]["property"] = {"detectedBreak": {"type": "SPACE"}}
    paragraph = {
        "words": words,
        "boundingBox": {"vertices": [
            {"x": 300, "y": 340}, {"x": 500, "y": 340}, {"x": 500, "y": 361}, {"x": 300, "y": 361},
        ]},
    }
    annotation = _annotation([paragraph], "KSPO DOME")
    blocks = _flatten_paragraphs(annotation)
    assert len(blocks) == 1
    assert blocks[0]["text"] == "KSPO DOME"


# 실사용 캡처로 확인된 회귀: 포스터 썸네일 텍스트 등 무관한 블록이 라벨보다 왼쪽에
# 섞여 들어와도(행의 첫 블록이 아니어도) 라벨을 찾아 값을 채택하는지 확인
def test_extract_fields_from_rows_finds_label_not_at_first_position():
    rows = [[
        {"text": "POSTER NOISE", "x0": 10, "y0": 100, "x1": 100, "y1": 130},
        {"text": "공연장소", "x0": 300, "y0": 100, "x1": 400, "y1": 130},
        {"text": "고려대학교 화정체육관", "x0": 550, "y0": 100, "x1": 800, "y1": 130},
    ]]
    fields, grid_start = _extract_fields_from_rows(rows)
    assert fields == {"location": "고려대학교 화정체육관"}
    assert grid_start == 0


# 실사용 캡처로 확인된 회귀: 햄버거 메뉴/뒤로가기 아이콘이 "< ="처럼 기호로만 오인식된
# 블록은 제목 후보에서 제외되고, 실제 글자가 있는 다음 후보를 채택하는지 확인
def test_extract_title_from_layout_skips_symbol_only_garbage():
    rows = _group_rows([
        {"text": "< =", "x0": 40, "y0": 240, "x1": 100, "y1": 300},
        {"text": "예매내역", "x0": 500, "y0": 239, "x1": 600, "y1": 293},
        {"text": "ZUTOMAYO INTENSE II", "x0": 48, "y0": 404, "x1": 400, "y1": 446},
    ])
    assert _extract_title_from_layout(rows, None)[0] == "ZUTOMAYO INTENSE II"


# 실사용 캡처(Vaundy 예매내역)로 확인된 회귀: 포스터 썸네일의 작은 텍스트 조각("ASIA")이
# 화면 폭 대부분을 차지하는 진짜 제목보다 먼저(위) 나와도, 폭이 좁으면 후보에서 제외하고
# 폭이 충분히 넓은 진짜 제목을 채택하는지 확인
def test_extract_title_from_layout_skips_narrow_poster_fragment():
    rows = _group_rows([
        {"text": "ASIA", "x0": 141, "y0": 425, "x1": 160, "y1": 433},
        {"text": "Vaundy ASIA ARENA TOUR 2026", "x0": 293, "y0": 474, "x1": 1125, "y1": 508},
    ])
    assert _extract_title_from_layout(rows, None)[0] == "Vaundy ASIA ARENA TOUR 2026"


# 실사용 캡처(Vaundy 예매내역)로 확인된 케이스: 제목이 화면 폭 제약으로 2줄에 걸쳐
# 줄바꿈되면("...HORO" I" + "N SEOUL", 단어 중간에서 끊김) 원본 title은 첫 줄 그대로
# 두되, 이어붙인 후보(공백 포함/미포함)를 함께 반환하는지 확인
def test_extract_title_from_layout_returns_wrap_continuation_variants():
    rows = _group_rows([
        {"text": "Vaundy ASIA ARENA TOUR 2026 \"HORO\" I", "x0": 293, "y0": 474, "x1": 1125, "y1": 508},
        {"text": "N SEOUL", "x0": 295, "y0": 529, "x1": 472, "y1": 558},
    ])
    title, wrap_variants = _extract_title_from_layout(rows, None)
    assert title == "Vaundy ASIA ARENA TOUR 2026 \"HORO\" I"
    assert "Vaundy ASIA ARENA TOUR 2026 \"HORO\" IN SEOUL" in wrap_variants
    assert "Vaundy ASIA ARENA TOUR 2026 \"HORO\" I N SEOUL" in wrap_variants


# 다음 행이 제목 행과 좌측 정렬이 크게 다르거나(줄바꿈 연속이 아니라 무관한 값 행일
# 가능성) 폭이 너무 좁으면 이어붙이기 후보를 만들지 않아야 함
def test_extract_title_from_layout_no_wrap_variants_when_next_row_misaligned():
    rows = _group_rows([
        {"text": "YUURI ARENA LIVE 2025 at SEOUL", "x0": 61, "y0": 518, "x1": 939, "y1": 560},
        {"text": "관람일시", "x0": 700, "y0": 700, "x1": 800, "y1": 730},
    ])
    title, wrap_variants = _extract_title_from_layout(rows, None)
    assert title == "YUURI ARENA LIVE 2025 at SEOUL"
    assert wrap_variants == []


# 화면 UI가 긴 제목을 "…"로 줄여서 보여주는 경우, 검색어를 오염시키지 않도록 제거
def test_strip_trailing_ellipsis_real_char():
    assert _strip_trailing_ellipsis("BTS WORLD TOUR…") == "BTS WORLD TOUR"


def test_strip_trailing_ellipsis_three_dots():
    assert _strip_trailing_ellipsis("BTS WORLD TOUR...") == "BTS WORLD TOUR"


# 진짜 마침표(문장부호)까지 지워버리면 안 되므로, 점 1~2개는 그대로 둠
def test_strip_trailing_ellipsis_does_not_touch_single_dot():
    assert _strip_trailing_ellipsis("BTS WORLD TOUR.") == "BTS WORLD TOUR."


def test_group_rows_clusters_by_y_and_sorts_by_x():
    a = {"text": "A", "x0": 100, "y0": 0, "y1": 20, "x1": 150}
    b = {"text": "B", "x0": 10, "y0": 5, "y1": 25, "x1": 60}
    c = {"text": "C", "x0": 10, "y0": 100, "y1": 120, "x1": 60}
    rows = _group_rows([a, b, c])
    assert [blk["text"] for blk in rows[0]] == ["B", "A"]
    assert [blk["text"] for blk in rows[1]] == ["C"]


def test_group_rows_empty():
    assert _group_rows([]) == []


# "라벨:값" 격자로 인식되면 title/date/time/location/platform이 좌표 기반으로 채워지는지 확인
def test_parse_ticket_fields_from_layout_full():
    annotation = _annotation(_BOOKING_HISTORY_PARAGRAPHS, _BOOKING_HISTORY_FULL_TEXT)
    result = _parse_ticket_fields_from_layout(annotation, _BOOKING_HISTORY_FULL_TEXT)
    assert result is not None
    assert result["title"] == "YUURI ARENA LIVE 2025 at SEOUL"
    assert result["date"] == "2025-05-04"
    assert result["time"] == "17:00"
    assert result["location"] == "KSPO DOME"
    assert result["platform"] == "티켓링크"
    assert result["seat"] is None
    assert result["event_type"] == "SOLO"


# "좌석(1)"처럼 라벨에 개수가 붙어도 정규화돼서 매칭되는지 확인
def test_parse_ticket_fields_from_layout_normalizes_seat_label_suffix():
    paragraphs = [
        _paragraph("관람일시", 40, 100, 160, 120),
        _paragraph("2026.04.19(일) 19:30", 300, 100, 560, 120),
        _paragraph("좌석(1)", 40, 140, 160, 160),
        _paragraph("일반석 1층 스탠딩B구역 입장번호065번", 300, 140, 650, 160),
    ]
    full_text = "관람일시\n2026.04.19(일) 19:30\n좌석(1)\n일반석 1층 스탠딩B구역 입장번호065번"
    result = _parse_ticket_fields_from_layout(_annotation(paragraphs, full_text), full_text)
    assert result is not None
    assert result["date"] == "2026-04-19"
    assert result["time"] == "19:30"
    assert result["seat"] == "일반석 1층 스탠딩B구역 입장번호065번"


# 매칭된 라벨이 datetime 하나뿐이면(최소 기준 미달) 격자로 판단하지 않고 None 반환
def test_parse_ticket_fields_from_layout_below_threshold_returns_none():
    paragraphs = [
        _paragraph("관람일시", 40, 100, 160, 120),
        _paragraph("2025.05.04(일) 17:00", 300, 100, 560, 120),
    ]
    full_text = "관람일시\n2025.05.04(일) 17:00"
    assert _parse_ticket_fields_from_layout(_annotation(paragraphs, full_text), full_text) is None


# 모바일 티켓처럼 "라벨 : 값"이 한 줄(한 문단)에 같이 인쇄된 경우엔 열이 안 나뉘어서
# 격자로 인식되지 않고 None을 반환하는지 확인 (기존 regex 경로로 폴백돼야 하는 케이스)
def test_parse_ticket_fields_from_layout_returns_none_for_single_column_lines():
    paragraphs = [
        _paragraph("인터파크 티켓", 40, 40, 300, 60),
        _paragraph("공연명 : BTS WORLD TOUR 2030", 40, 80, 500, 100),
        _paragraph("공연일시 : 2030.06.01 (토) 오후 6시", 40, 120, 500, 140),
        _paragraph("공연장소 : 잠실올림픽주경기장", 40, 160, 500, 180),
        _paragraph("좌석 : R석 A구역 12열 15번", 40, 200, 500, 220),
        _paragraph("결제금액 : 110,000원", 40, 240, 500, 260),
        _paragraph("발송예정일 : 2030.05.20", 40, 280, 500, 300),
    ]
    result = _parse_ticket_fields_from_layout(
        _annotation(paragraphs, _INTERPARK_TICKET), _INTERPARK_TICKET
    )
    assert result is None


# 헤더 영역의 네비게이션 타이틀/뱃지는 건너뛰고 실제 공연명을 채택하는지 확인
def test_extract_title_from_layout_skips_chrome_text():
    rows = _group_rows([
        {"text": "상세내역", "x0": 40, "y0": 40, "x1": 200, "y1": 70},
        {"text": "배송완료", "x0": 40, "y0": 80, "x1": 160, "y1": 100},
        {"text": "YUURI ARENA LIVE 2025 at SEOUL", "x0": 40, "y0": 120, "x1": 600, "y1": 160},
    ])
    assert _extract_title_from_layout(rows, None)[0] == "YUURI ARENA LIVE 2025 at SEOUL"


# 실사용 캡처(2026-08-03)로 확인된 회귀: 헤더 맨 위 화면 상태표시줄(시계 "2:37", 신호/배터리
# 아이콘 오인식 "l (41)")이 제목 후보로 잘못 채택되던 문제. 상태표시줄은 걸러내고
# 그 아래의 진짜 공연명을 채택해야 함
def test_extract_title_from_layout_skips_status_bar():
    rows = _group_rows([
        {"text": "2:37", "x0": 170, "y0": 81, "x1": 273, "y1": 115},
        {"text": "l (41)", "x0": 862, "y0": 80, "x1": 1102, "y1": 119},
        {"text": "<상세내역", "x0": 67, "y0": 247, "x1": 327, "y1": 301},
        {"text": "배송완료", "x0": 90, "y0": 424, "x1": 203, "y1": 453},
        {"text": "YUURI ARENA LIVE 2025 at SEOUL", "x0": 61, "y0": 518, "x1": 939, "y1": 560},
    ])
    assert _extract_title_from_layout(rows, None)[0] == "YUURI ARENA LIVE 2025 at SEOUL"


# _extract_ticket_info 통합 테스트 (Vision 응답 1회 안에서 격자 파싱과 폴백이 갈리는지)

@pytest.mark.asyncio
async def test_extract_ticket_info_uses_layout_when_grid_detected():
    annotation = _annotation(_BOOKING_HISTORY_PARAGRAPHS, _BOOKING_HISTORY_FULL_TEXT)
    with _httpx_post_mock(200, {"responses": [annotation]}):
        result = await extract_ticket_info(b"fake-image", "image/jpeg")
    assert result["title"] == "YUURI ARENA LIVE 2025 at SEOUL"
    assert result["date"] == "2025-05-04"
    assert result["platform"] == "티켓링크"


# 격자가 인식 안 되는 이미지는 extract_ticket_info가 기존 regex 파이프라인 결과와
# 동일한 값을 돌려주는지 확인 (Vision을 두 번 호출하지 않고, 같은 응답을 재활용해서 판단)
@pytest.mark.asyncio
async def test_extract_ticket_info_falls_back_to_regex_pipeline():
    paragraphs = [
        _paragraph("인터파크 티켓", 40, 40, 300, 60),
        _paragraph("공연명 : BTS WORLD TOUR 2030", 40, 80, 500, 100),
        _paragraph("공연일시 : 2030.06.01 (토) 오후 6시", 40, 120, 500, 140),
        _paragraph("공연장소 : 잠실올림픽주경기장", 40, 160, 500, 180),
        _paragraph("좌석 : R석 A구역 12열 15번", 40, 200, 500, 220),
        _paragraph("결제금액 : 110,000원", 40, 240, 500, 260),
        _paragraph("발송예정일 : 2030.05.20", 40, 280, 500, 300),
    ]
    annotation = _annotation(paragraphs, _INTERPARK_TICKET)
    with _httpx_post_mock(200, {"responses": [annotation]}):
        result = await extract_ticket_info(b"fake-image", "image/jpeg")
    assert result == _parse_ticket_fields(_INTERPARK_TICKET)


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


# 일부 모바일 티켓 앱(NOL ticket 등)은 날짜를 월/일/연도 순서로 한 줄씩 세로로 나열함
# (한 줄 안에 이어진 형태가 아니라서 기존 _DATE_RE로는 못 잡던 케이스)
def test_extract_concert_date_stacked_fallback():
    text = "VAUNDY\n9/19-20\nSEOUL\n09\n20\n2026\n인스파이어 아레나"
    assert _extract_concert_date(text) == "2026-09-20"


# 세로 나열 폴백은 다른 패턴이 다 실패했을 때만 쓰이고, 라벨/일반 날짜가 있으면
# 그쪽을 우선하는지 확인 (기존 로직을 해치지 않는지 회귀 방지)
def test_extract_concert_date_stacked_fallback_does_not_override_normal_match():
    text = "공연일시 : 2030.06.01\n09\n20\n2026"
    assert _extract_concert_date(text) == "2030-06-01"


# 세로 나열 폴백이 범위를 벗어난 값(예: 13월)은 걸러내는지 확인
def test_extract_concert_date_stacked_fallback_rejects_invalid_month():
    text = "13\n20\n2026"
    assert _extract_concert_date(text) is None


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


# 실제 티켓 정보가 뽑히는("의미있는") 스캔은 유저당 시간당 10회로 제한되는지 테스트
# (Vision 호출 비용 남용 방지 - 카메라 오인식 문제와 별개로, 진짜 스캔 시도 자체의 상한)
# 연달아 호출하는 테스트라 스캔 쿨다운(is_within_scan_cooldown)에 걸리지 않도록 꺼둠 -
# 쿨다운 자체는 별도 테스트(test_scan_cooldown_skips_vision_call_on_rapid_repeat)에서 검증
@pytest.mark.asyncio
async def test_scan_meaningful_rate_limited_after_10_calls_per_hour(get_auth_token):
    headers = {"Authorization": f"Bearer {get_auth_token}"}
    statuses = []
    with (
        _ocr_mock(_SAMPLE_EXTRACTED),
        kopis_mock(_make_kopis_xml("PF_OCR_RATE", "테스트 공연")),
        patch("app.api.v1.endpoints.concerts.is_within_scan_cooldown", return_value=False),
    ):
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


# 짧은 간격(스캔 쿨다운 이내)으로 연달아 온 두 번째 요청은 Vision을 실제로 호출하지 않고
# 빈 결과를 바로 반환하는지 테스트 (카메라 오인식 연사 시 Vision 비용 절감용)
@pytest.mark.asyncio
async def test_scan_cooldown_skips_vision_call_on_rapid_repeat(get_auth_token):
    headers = {"Authorization": f"Bearer {get_auth_token}"}
    with (
        _ocr_mock(_SAMPLE_EXTRACTED) as mock_extract,
        kopis_mock(_make_kopis_xml("PF_OCR_COOLDOWN", "테스트 공연")),
    ):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            first = await ac.post(
                "/api/v1/concerts/scan",
                files={"image": ("ticket.jpg", b"fake-image", "image/jpeg")},
                headers=headers,
            )
            second = await ac.post(
                "/api/v1/concerts/scan",
                files={"image": ("ticket.jpg", b"fake-image", "image/jpeg")},
                headers=headers,
            )

    assert first.status_code == 200
    assert first.json()["extracted"]["title"] == "BTS World Tour"
    assert second.status_code == 200
    assert second.json()["extracted"]["title"] is None
    assert mock_extract.call_count == 1


# 카메라 정렬 인식이 티켓이 아닌 사물을 오인식해서 아무 필드도 못 뽑은 스캔(전부 None)은
# "의미있는 스캔" 10회 한도를 깎아먹지 않아야 함 - 10회보다 많이 반복해도 전부 200
@pytest.mark.asyncio
async def test_scan_empty_result_does_not_count_toward_meaningful_limit(get_auth_token):
    headers = {"Authorization": f"Bearer {get_auth_token}"}
    empty_extracted = {
        "title": None,
        "date": None,
        "time": None,
        "shipping_date": None,
        "location": None,
        "seat": None,
        "platform": None,
        "price": None,
        "event_type": None,
    }
    statuses = []
    with _ocr_mock(empty_extracted):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            for _ in range(15):
                response = await ac.post(
                    "/api/v1/concerts/scan",
                    files={"image": ("junk.jpg", b"fake-image", "image/jpeg")},
                    headers=headers,
                )
                statuses.append(response.status_code)

    assert statuses == [200] * 15


# 빈 스캔이 "의미있는 스캔" 한도는 안 깎아도, 순수 어뷰징(요청 자체를 무한 반복) 방지를 위한
# 하드 상한(30회/시간)은 그대로 적용되는지 테스트
@pytest.mark.asyncio
async def test_scan_hard_ceiling_applies_even_to_empty_results(get_auth_token):
    headers = {"Authorization": f"Bearer {get_auth_token}"}
    empty_extracted = {
        "title": None,
        "date": None,
        "time": None,
        "shipping_date": None,
        "location": None,
        "seat": None,
        "platform": None,
        "price": None,
        "event_type": None,
    }
    statuses = []
    with _ocr_mock(empty_extracted):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            for _ in range(31):
                response = await ac.post(
                    "/api/v1/concerts/scan",
                    files={"image": ("junk.jpg", b"fake-image", "image/jpeg")},
                    headers=headers,
                )
                statuses.append(response.status_code)

    assert statuses[:30] == [200] * 30
    assert statuses[30] == 429


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
