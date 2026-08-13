from unittest.mock import AsyncMock, MagicMock, patch
from datetime import date

import pytest

from app.services.setlistfm import (
    _artist_name_matches,
    search_setlists,
    search_setlists_by_artist,
)


# "Nell" 검색 시 Nell Mescal/Nellie McKay 등 다른 서양 아티스트가 섞여 들어오는 실제 관측
# 사례 기반 - _artist_name_matches 단위 테스트

def test_artist_name_matches_same_script_correct_match():
    assert _artist_name_matches("Nell", "NELL") is True  # 대소문자만 다름


def test_artist_name_matches_same_script_different_artist():
    assert _artist_name_matches("Nell", "Nell Mescal") is False
    assert _artist_name_matches("Nell", "Nellie McKay") is False
    assert _artist_name_matches("Nell", "Nell Davies") is False


def test_artist_name_matches_cross_script_abstains():
    # 한글 검색어 vs 로마자 후보명 - Setlist.fm이 내부적으로 음차 변환을 처리하므로
    # 문자열 유사도로 검증하지 않고 통과시킴(정답까지 걸러내는 역효과 방지)
    assert _artist_name_matches("넬", "NELL") is True
    assert _artist_name_matches("넬", "Nell") is True


def test_artist_name_matches_empty_candidate_rejected():
    assert _artist_name_matches("Nell", "") is False


# search_setlists/search_setlists_by_artist가 실제로 이 필터를 적용해서 오염된 후보를
# 걸러내는지 통합 테스트

def _setlistfm_response_mock(payload: dict, status_code: int = 200):
    mock_response = MagicMock()
    mock_response.status_code = status_code
    mock_response.json = MagicMock(return_value=payload)
    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = AsyncMock(return_value=mock_response)
    return patch("app.services.setlistfm.httpx.AsyncClient", return_value=mock_client)


def _raw_setlist(setlistfm_id: str, artist: str, event_date: str = "01-06-2030") -> dict:
    return {
        "id": setlistfm_id,
        "eventDate": event_date,
        "artist": {"name": artist},
        "venue": {"name": "테스트공연장", "city": {"name": "서울"}},
        "sets": {"set": [{"song": [{"name": "곡1"}]}]},
        "url": f"https://www.setlist.fm/setlist/test/{setlistfm_id}.html",
    }


@pytest.mark.asyncio
async def test_search_setlists_filters_out_mismatched_artist():
    payload = {
        "type": "setlists",
        "itemsPerPage": 20,
        "page": 1,
        "total": 2,
        "setlist": [
            _raw_setlist("SF_REAL", "Nell"),
            _raw_setlist("SF_WRONG", "Nell Mescal"),
        ],
    }
    with _setlistfm_response_mock(payload):
        results = await search_setlists("Nell", date(2030, 6, 1))

    assert len(results) == 1
    assert results[0]["setlistfm_id"] == "SF_REAL"


@pytest.mark.asyncio
async def test_search_setlists_by_artist_filters_out_mismatched_artist():
    payload = {
        "type": "setlists",
        "itemsPerPage": 20,
        "page": 1,
        "total": 3,
        "setlist": [
            _raw_setlist("SF_REAL_1", "NELL"),
            _raw_setlist("SF_WRONG_1", "Nellie McKay"),
            _raw_setlist("SF_WRONG_2", "Nell Davies"),
        ],
    }
    with _setlistfm_response_mock(payload):
        results = await search_setlists_by_artist("Nell", pages=1)

    assert len(results) == 1
    assert results[0]["id"] == "SF_REAL_1"


@pytest.mark.asyncio
async def test_search_setlists_by_artist_korean_query_unaffected():
    # 한글 검색어는 로마자 후보명과 문자 체계가 달라 필터가 통과시킴(회귀 확인용)
    payload = {
        "type": "setlists",
        "itemsPerPage": 20,
        "page": 1,
        "total": 1,
        "setlist": [_raw_setlist("SF_KR_1", "NELL")],
    }
    with _setlistfm_response_mock(payload):
        results = await search_setlists_by_artist("넬", pages=1)

    assert len(results) == 1
