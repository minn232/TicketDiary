from unittest.mock import AsyncMock, MagicMock, patch
from datetime import date

import pytest

from app.services.setlistfm import (
    _artist_matches,
    search_setlists,
    search_setlists_by_artist,
)

# 실제 Setlist.fm 응답/운영 DB에서 확인한 mbid
_JISOO_MBID = "f906154a-7011-49c3-8f6a-44ca83311b08"
_OUR_KIM_JISOO_MBID = "ea4f1fec-addd-4466-934e-9a6cf5fb4b9b"
_KIM_JONGHYEON_MBID = "e06ad1e3-0513-436a-b9a4-db523e731321"
_JONGHYUN_MBID = "2cb1105c-5f6d-426f-91a5-7b80f2fc68ff"
_NELL_MBID = "e156615d-3ddd-4491-9584-4b9d971472c4"


# "Nell" 검색 시 Nell Mescal/Nellie McKay 등 다른 서양 아티스트가 섞여 들어오는 실제 관측
# 사례 기반 - mbid 모를 때의 이름 비교

def test_artist_matches_same_script_correct_match():
    assert _artist_matches("Nell", "NELL", None, None) is True  # 대소문자만 다름


def test_artist_matches_same_script_different_artist():
    assert _artist_matches("Nell", "Nell Mescal", None, None) is False
    assert _artist_matches("Nell", "Nellie McKay", None, None) is False
    assert _artist_matches("Nell", "Nell Davies", None, None) is False


def test_artist_matches_cross_script_without_mbid_rejected():
    # 본명 별칭으로 검색된 다른 아티스트(김현정→SEOLA)를 이름으로는 구분할 수 없어서 거절
    assert _artist_matches("김현정", "SEOLA", "d6c7983b-3a92-4418-a6f4-b3f8d7525d5c", None) is False
    assert _artist_matches("넬", "NELL", _NELL_MBID, None) is False


def test_artist_matches_empty_candidate_rejected():
    assert _artist_matches("Nell", "", None, None) is False
    assert _artist_matches("넬", "", None, _NELL_MBID) is False


# 우리 canonical mbid를 알면 이름과 무관하게 mbid로만 판정

def test_artist_matches_mbid_same_person_across_scripts():
    assert _artist_matches("넬", "NELL", _NELL_MBID, _NELL_MBID) is True


def test_artist_matches_mbid_rejects_real_name_alias_of_other_artist():
    # 김지수(다른 가수)로 검색하면 본명이 같은 JISOO가 나옴
    assert _artist_matches("김지수", "JISOO", _JISOO_MBID, _OUR_KIM_JISOO_MBID) is False
    # 김종현은 Kim Jonghyeon만 본인, 같은 본명의 JONGHYUN은 제외
    assert _artist_matches("김종현", "Kim Jonghyeon", _KIM_JONGHYEON_MBID, _KIM_JONGHYEON_MBID) is True
    assert _artist_matches("김종현", "JONGHYUN", _JONGHYUN_MBID, _KIM_JONGHYEON_MBID) is False


def test_artist_matches_mbid_rejects_candidate_without_mbid():
    assert _artist_matches("Nell", "Nell", None, _NELL_MBID) is False


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


def _raw_setlist(
    setlistfm_id: str, artist: str, event_date: str = "01-06-2030", mbid: str | None = None
) -> dict:
    return {
        "id": setlistfm_id,
        "eventDate": event_date,
        "artist": {"name": artist, "mbid": mbid},
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
async def test_search_setlists_by_artist_korean_query_with_mbid():
    # 한글 검색어라도 mbid가 같으면 로마자 후보명(NELL)을 본인으로 인정
    payload = {
        "type": "setlists",
        "itemsPerPage": 20,
        "page": 1,
        "total": 1,
        "setlist": [_raw_setlist("SF_KR_1", "NELL", mbid=_NELL_MBID)],
    }
    with _setlistfm_response_mock(payload):
        results = await search_setlists_by_artist("넬", pages=1, artist_mbid=_NELL_MBID)

    assert len(results) == 1


@pytest.mark.asyncio
async def test_search_setlists_by_artist_korean_query_without_mbid_rejected():
    # mbid를 모르는 한글 검색어는 로마자 후보를 본인인지 확인할 방법이 없어 거절
    payload = {
        "type": "setlists",
        "itemsPerPage": 20,
        "page": 1,
        "total": 1,
        "setlist": [_raw_setlist("SF_KR_1", "SEOLA", mbid="d6c7983b-3a92-4418-a6f4-b3f8d7525d5c")],
    }
    with _setlistfm_response_mock(payload):
        results = await search_setlists_by_artist("김현정", pages=1)

    assert results == []


@pytest.mark.asyncio
async def test_search_setlists_filters_real_name_alias_by_mbid():
    # 김종현 실측 응답 - 본인(Kim Jonghyeon)과 본명이 같은 JONGHYUN이 섞여 옴
    payload = {
        "type": "setlists",
        "itemsPerPage": 20,
        "page": 1,
        "total": 2,
        "setlist": [
            _raw_setlist("SF_REAL", "Kim Jonghyeon", mbid=_KIM_JONGHYEON_MBID),
            _raw_setlist("SF_WRONG", "JONGHYUN", mbid=_JONGHYUN_MBID),
        ],
    }
    with _setlistfm_response_mock(payload):
        results = await search_setlists("김종현", date(2030, 6, 1), artist_mbid=_KIM_JONGHYEON_MBID)

    assert [r["setlistfm_id"] for r in results] == ["SF_REAL"]


@pytest.mark.asyncio
async def test_search_setlists_by_artist_accepts_merged_old_mbid():
    # 혁오 실측 - Setlist.fm은 MusicBrainz에서 병합된 옛 mbid를 쓰고, 우리 canonical은 병합 후 mbid
    old_mbid = "f619b92a-a1b5-481c-8405-df35fb7846f1"
    current_mbid = "8b64a68f-eb63-48dd-80d9-1c2abcdf1970"
    payload = {
        "type": "setlists",
        "itemsPerPage": 20,
        "page": 1,
        "total": 2,
        "setlist": [
            _raw_setlist("SF_HYUKOH_1", "hyukoh", mbid=old_mbid),
            _raw_setlist("SF_HYUKOH_2", "hyukoh", mbid=old_mbid),
        ],
    }
    lookup = AsyncMock(return_value=current_mbid)
    with _setlistfm_response_mock(payload), patch("app.services.setlistfm.fetch_current_mbid", new=lookup):
        results = await search_setlists_by_artist("혁오", pages=1, artist_mbid=current_mbid)

    assert [r["id"] for r in results] == ["SF_HYUKOH_1", "SF_HYUKOH_2"]
    lookup.assert_awaited_once_with(old_mbid)  # 같은 mbid는 한 번만 조회
