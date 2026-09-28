import io
from unittest.mock import AsyncMock, patch

import pytest
from PIL import Image

from app.services.timetable_ranges import compute_timetable_ranges, find_timetable_ranges


# 단어 목록 [(text, x0, y0, x1, y1), ...]을 Vision fullTextAnnotation 형태로 감쌈 (단어마다 문단 하나)
def _annotation(words, page_height=None):
    paragraphs = [
        {
            "words": [
                {
                    "symbols": [{"text": ch} for ch in text],
                    "boundingBox": {"vertices": [{"x": x0, "y": y0}, {"x": x1, "y": y0}, {"x": x1, "y": y1}, {"x": x0, "y": y1}]},
                }
            ]
        }
        for text, x0, y0, x1, y1 in words
    ]
    page = {"blocks": [{"paragraphs": paragraphs}]}
    if page_height is not None:
        page["height"] = page_height
    return {"fullTextAnnotation": {"pages": [page]}}


# y 위치에 "HH:MM 아티스트" 한 줄 (시간과 아티스트가 다른 문단으로 잡히는 실제 Vision 응답 흉내)
def _time_row(y, time_text="13:30", artist="아티스트"):
    return [(time_text, 100, y, 180, y + 20), (artist, 300, y + 2, 500, y + 22)]


def test_find_ranges_single_cluster_with_padding():
    words = _time_row(1000) + _time_row(1100) + _time_row(1200)
    # 구간 1000~1222, 높이 222 → 여백 222*0.15+30 = 63.3
    assert find_timetable_ranges(_annotation(words), 5000) == [(936, 1285)]


# 1~2줄짜리 시간 줄(예매일정 안내 등)은 시간표로 안 봄
def test_find_ranges_drops_short_clusters():
    words = _time_row(300) + _time_row(400) + _time_row(3000)
    assert find_timetable_ranges(_annotation(words), 5000) == []


# 멀리 떨어진 날짜별 시간표 블록은 각각 별도 구간으로
def test_find_ranges_multiple_clusters():
    day1 = _time_row(1000) + _time_row(1100) + _time_row(1200)
    day2 = _time_row(5000) + _time_row(5100) + _time_row(5200)
    ranges = find_timetable_ranges(_annotation(day1 + day2), 8000)
    assert len(ranges) == 2
    assert ranges[0][0] < 1000 and ranges[0][1] > 1220
    assert ranges[1][0] < 5000 and ranges[1][1] > 5220


# Vision이 "13:30"을 "13"/":"/"30"으로 쪼개 "13 : 30"으로 재조합돼도 시간 줄로 인식
def test_find_ranges_matches_split_colon_time():
    words = []
    for y in (1000, 1100, 1200):
        words += [("13", 100, y, 120, y + 20), (":", 122, y, 126, y + 20), ("30", 128, y, 150, y + 20)]
    assert len(find_timetable_ranges(_annotation(words), 5000)) == 1


# 날짜가 같은 줄에 붙은 시간 줄(예매일정/배송 안내)은 시간표로 안 봄 - Vision 띄어쓰기 형태 포함
def test_find_ranges_ignores_lines_with_dates():
    words = []
    for y, date in ((1000, "2026년 9월 14일(월) 14:00"), (1100, "2026 년 9 월 17 일 ( 목 ) 20:00"), (1200, "2026.9.22 15:00")):
        words.append((date, 100, y, 600, y + 20))
    assert find_timetable_ranges(_annotation(words), 5000) == []


# 단독 공연 당일 일정표(날짜는 표 머리에만)는 그대로 잡힘
def test_find_ranges_keeps_day_of_schedule():
    words = [("11월 7일(토)", 300, 950, 500, 970)]
    words += _time_row(1000, "4:00PM", "티켓부스 오픈") + _time_row(1100, "5:00PM", "입장") + _time_row(1200, "6:00PM", "공연 시작")
    assert len(find_timetable_ranges(_annotation(words), 5000)) == 1


def test_find_ranges_clamps_to_image_bounds():
    words = _time_row(0) + _time_row(100) + _time_row(200)
    assert find_timetable_ranges(_annotation(words), 240) == [(0, 240)]


def test_find_ranges_no_text():
    assert find_timetable_ranges({}, 1000) == []


def _png_bytes(height):
    buf = io.BytesIO()
    Image.new("RGB", (100, height), "white").save(buf, format="PNG")
    return buf.getvalue()


@pytest.mark.asyncio
async def test_compute_ranges_returns_lists():
    words = _time_row(1000) + _time_row(1100) + _time_row(1200)
    with patch("app.services.timetable_ranges._call_vision", new=AsyncMock(return_value=_annotation(words, 5000))):
        assert await compute_timetable_ranges(_png_bytes(5000)) == [[936, 1285]]


# Vision이 이미지를 절반으로 줄여 읽었으면 좌표를 원본 픽셀 기준으로 되돌림
@pytest.mark.asyncio
async def test_compute_ranges_rescales_when_vision_downscaled():
    words = _time_row(500) + _time_row(550) + _time_row(600)
    with patch("app.services.timetable_ranges._call_vision", new=AsyncMock(return_value=_annotation(words, 2500))):
        [[top, bottom]] = await compute_timetable_ranges(_png_bytes(5000))
    assert top < 1000 and bottom > 1240


# Vision 실패는 None(미계산)으로 - 스크린샷 저장 흐름을 막으면 안 됨
@pytest.mark.asyncio
async def test_compute_ranges_returns_none_on_vision_failure():
    with patch("app.services.timetable_ranges._call_vision", new=AsyncMock(side_effect=Exception("quota"))):
        assert await compute_timetable_ranges(_png_bytes(1000)) is None


@pytest.mark.asyncio
async def test_compute_ranges_empty_when_no_timetable():
    with patch("app.services.timetable_ranges._call_vision", new=AsyncMock(return_value={})):
        assert await compute_timetable_ranges(_png_bytes(1000)) == []
