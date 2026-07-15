from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from httpx import AsyncClient, ASGITransport

from app.main import app
from app.services.kopis import _venue_candidates, _venue_overlaps
from app.services.site_aliases import find_site_key
from conftest import _get_token, kopis_mock


# 헬퍼

# KOPIS 가짜 API
def _make_kopis_xml(
    kopis_id: str, name: str, start: str, end: str, artist: str = "", dtguidance: str = ""
) -> bytes:
    crew = f"<prfcrew>출연: {artist}</prfcrew>" if artist else ""
    dt = f"<dtguidance>{dtguidance}</dtguidance>" if dtguidance else ""
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f"<dbs><db>"
        f"<mt20id>{kopis_id}</mt20id>"
        f"<prfnm>{name}</prfnm>"
        f"<prfpdfrom>{start}</prfpdfrom>"
        f"<prfpdto>{end}</prfpdto>"
        f"<fcltynm>테스트공연장</fcltynm>"
        f'<poster>https://example.com/poster.jpg</poster>'
        f"<genrenm>팝</genrenm>"
        f"<prfstate>공연예정</prfstate>"
        f"{crew}"
        f"<pcseguidance>VIP석 150,000원, R석 110,000원</pcseguidance>"
        f"{dt}"
        f"<sty>공연 소개</sty>"
        f"</db></dbs>"
    ).encode("utf-8")


# 빈 XML 응답 (검색 결과 없음)
_EMPTY_XML = b'<?xml version="1.0" encoding="UTF-8"?><dbs></dbs>'


# 공연 검색 테스트

# KOPIS 검색 성공 테스트
@pytest.mark.asyncio
async def test_search_concerts_success():
    token = await _get_token()
    xml = _make_kopis_xml("PF_SEARCH_001", "테스트 콘서트", "2030.06.01", "2030.06.30", "테스트아티스트")
    with kopis_mock(xml):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                "/api/v1/concerts/search",
                params={"keyword": "테스트"},
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 200
    data = response.json()
    assert len(data) == 1
    assert data[0]["kopis_id"] == "PF_SEARCH_001"
    assert data[0]["name"] == "테스트 콘서트"


# 검색 결과 없음 테스트
@pytest.mark.asyncio
async def test_search_concerts_empty_result():
    token = await _get_token()
    with kopis_mock(_EMPTY_XML):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                "/api/v1/concerts/search",
                params={"keyword": "없는공연xyz"},
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 200
    assert response.json() == []


# KOPIS API 오류 시 502 반환 테스트
@pytest.mark.asyncio
async def test_search_concerts_kopis_502():
    token = await _get_token()
    with kopis_mock(b"", status_code=500):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                "/api/v1/concerts/search",
                params={"keyword": "테스트"},
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 502


# 동일 공연 중복 검색 시 같은 ID 반환 테스트
@pytest.mark.asyncio
async def test_search_concerts_upsert_same_id():
    token = await _get_token()
    xml = _make_kopis_xml("PF_UPSERT_001", "업서트 테스트", "2030.07.01", "2030.07.31")
    with kopis_mock(xml):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res1 = await ac.get(
                "/api/v1/concerts/search",
                params={"keyword": "업서트"},
                headers={"Authorization": f"Bearer {token}"},
            )
            res2 = await ac.get(
                "/api/v1/concerts/search",
                params={"keyword": "업서트"},
                headers={"Authorization": f"Bearer {token}"},
            )

    assert res1.json()[0]["id"] == res2.json()[0]["id"]


# 다단어 검색이 전부 실패하면 1단어까지 축소해서 재시도하는지 테스트
# (KOPIS 등록명이 OCR 원문과 구두점/부제가 달라도 맨 앞 단어=아티스트명만으로 걸리는 경우가 많음)
@pytest.mark.asyncio
async def test_search_concerts_reduces_to_single_word():
    token = await _get_token()
    single_word_xml = _make_kopis_xml("PF_ONEWORD_001", "SURL concert, ?YRU?", "2030.06.01", "2030.06.30")

    async def _mock_get(url, params=None, **kwargs):
        mock_response = MagicMock()
        mock_response.status_code = 200
        keyword = (params or {}).get("shprfnm", "")
        mock_response.content = single_word_xml if keyword.strip() == "SURL" else _EMPTY_XML
        return mock_response

    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = _mock_get

    with patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                "/api/v1/concerts/search",
                params={"keyword": "SURL concert'? YRU?'"},
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 200
    data = response.json()
    assert len(data) == 1
    assert data[0]["kopis_id"] == "PF_ONEWORD_001"


# 2자 이하로 줄어드는 축소 단계는 건너뛰는지 테스트
# (로마자 아티스트명이 "HA/HYUN/SANG"처럼 쪼개져 있으면 "HA"만으로 검색 시 무관한 결과가 대량으로 걸림)
@pytest.mark.asyncio
async def test_search_concerts_skips_too_short_reduction():
    token = await _get_token()
    seen_keywords = []

    async def _mock_get(url, params=None, **kwargs):
        keyword = (params or {}).get("shprfnm", "")
        seen_keywords.append(keyword)
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.content = _EMPTY_XML
        return mock_response

    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = _mock_get

    with patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                "/api/v1/concerts/search",
                params={"keyword": "HA HYUN SANG CONCERT"},
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 200
    assert response.json() == []
    assert "HA" not in [k.strip() for k in seen_keywords]


# 맨 앞이 연도인 제목은 연도를 떼어내고 검색하는지, 연도 단독으로는 검색하지 않는지 테스트
# (끝단어 축소만으로는 연도만 남을 수 있는데, 연도 하나는 너무 광범위해 무관한 결과가 대량으로 걸림)
@pytest.mark.asyncio
async def test_search_concerts_strips_leading_year():
    token = await _get_token()
    xml = _make_kopis_xml("PF_YEAR_001", "렛츠락 페스티벌", "2025.09.06", "2025.09.07")
    seen_keywords = []

    async def _mock_get(url, params=None, **kwargs):
        keyword = (params or {}).get("shprfnm", "")
        seen_keywords.append(keyword)
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.content = xml if keyword.strip() == "렛츠락 페스티벌" else _EMPTY_XML
        return mock_response

    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = _mock_get

    with patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                "/api/v1/concerts/search",
                params={"keyword": "2025 렛츠락 페스티벌"},
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 200
    data = response.json()
    assert len(data) == 1
    assert data[0]["kopis_id"] == "PF_YEAR_001"
    assert "2025" not in [k.strip() for k in seen_keywords]


# 결과가 API 상한(rows=50)에 도달하면 검색어가 너무 광범위하다고 보고 버리는지 테스트
# (예: "ONE"이 "TONE"/"Resone" 등 무관한 공연 이름에 부분일치해서 대량으로 걸리는 경우)
@pytest.mark.asyncio
async def test_search_concerts_skips_result_hitting_row_cap():
    token = await _get_token()
    many_dbs = "".join(
        f"<db><mt20id>PF_MANY_{i:03d}</mt20id><prfnm>공연{i}</prfnm>"
        f"<prfpdfrom>2030.01.{(i % 27) + 1:02d}</prfpdfrom><prfpdto>2030.01.{(i % 27) + 1:02d}</prfpdto>"
        f"<fcltynm>테스트공연장</fcltynm><poster></poster></db>"
        for i in range(50)
    )
    many_xml = f'<?xml version="1.0" encoding="UTF-8"?><dbs>{many_dbs}</dbs>'.encode("utf-8")

    async def _mock_get(url, params=None, **kwargs):
        keyword = (params or {}).get("shprfnm", "")
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.content = many_xml if keyword.strip() == "ONE" else _EMPTY_XML
        return mock_response

    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = _mock_get

    with patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                "/api/v1/concerts/search",
                params={"keyword": "ONE OK ROCK"},
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 200
    assert response.json() == []


# 후보가 여러 건일 때 요청 날짜 범위와 실제로 겹치는 공연이 앞쪽으로 정렬되는지 테스트
# (동명이인/유사 제목으로 여러 건이 잡혀도 정확한 회차가 1순위 후보가 되어야 함)
@pytest.mark.asyncio
async def test_search_concerts_sorts_candidates_by_date_match():
    token = await _get_token()
    dbs = "".join(
        f"<db><mt20id>{kid}</mt20id><prfnm>SURL {kid}</prfnm>"
        f"<prfpdfrom>{start}</prfpdfrom><prfpdto>{end}</prfpdto>"
        f"<fcltynm>테스트공연장</fcltynm><poster></poster></db>"
        for kid, start, end in [
            ("PF_FAR_001", "2024.02.02", "2024.02.02"),
            ("PF_NEAR_001", "2024.04.27", "2024.04.28"),
            ("PF_MID_001", "2024.06.26", "2024.06.26"),
        ]
    )
    xml = f'<?xml version="1.0" encoding="UTF-8"?><dbs>{dbs}</dbs>'.encode("utf-8")

    with kopis_mock(xml):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                "/api/v1/concerts/search",
                params={
                    "keyword": "SURL",
                    "start_date": "2024-01-29",
                    "end_date": "2024-07-27",
                },
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 200
    data = response.json()
    assert len(data) == 3
    assert data[0]["kopis_id"] == "PF_NEAR_001"


# 공연 상세 조회 테스트

# KOPIS에서 상세 조회 성공 테스트
@pytest.mark.asyncio
async def test_get_concert_detail_from_kopis():
    token = await _get_token()
    xml = _make_kopis_xml("PF_DETAIL_001", "상세 테스트 콘서트", "2030.08.01", "2030.08.31", "아티스트A")
    with kopis_mock(xml):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                "/api/v1/concerts/PF_DETAIL_001",
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 200
    data = response.json()
    assert data["kopis_id"] == "PF_DETAIL_001"
    assert data["name"] == "상세 테스트 콘서트"
    assert "아티스트A" in data["artist_name"]
    assert data["price"] == [
        {"seat_type": "VIP석", "price": 150000},
        {"seat_type": "R석", "price": 110000},
    ]


# KOPIS relates의 relatenm이 서비스명(NOL) 대신 운영사명(놀유니버스)으로 오는 경우도
# INTERPARK로 정규화되는지 테스트 (안 되면 직접 예매링크를 버리고 이름검색으로 폴백하게 됨)
def test_normalize_site_name_nol_universe():
    assert find_site_key("놀유니버스") == "INTERPARK"


# dtguidance 시간이 단일값으로 통일되면 start_time 파싱 테스트
@pytest.mark.asyncio
async def test_get_concert_detail_parses_unambiguous_start_time():
    token = await _get_token()
    xml = _make_kopis_xml(
        "PF_TIME_001", "시간 테스트 콘서트", "2030.10.01", "2030.10.01",
        dtguidance="화~금 19:30, 토 19:30",
    )
    with kopis_mock(xml):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                "/api/v1/concerts/PF_TIME_001",
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 200
    assert response.json()["start_time"] == "19:30"


# dtguidance에 요일/회차별로 다른 시간이 섞여 있으면 대표값을 정할 수 없어 start_time이 None인지 테스트
@pytest.mark.asyncio
async def test_get_concert_detail_ambiguous_start_time_is_none():
    token = await _get_token()
    xml = _make_kopis_xml(
        "PF_TIME_002", "시간 모호 콘서트", "2030.10.05", "2030.10.05",
        dtguidance="토 15:00,19:00 / 일 15:00",
    )
    with kopis_mock(xml):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                "/api/v1/concerts/PF_TIME_002",
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 200
    assert response.json()["start_time"] is None


# DB 조회 테스트
@pytest.mark.asyncio
async def test_get_concert_detail_db_cache():
    token = await _get_token()
    xml = _make_kopis_xml("PF_CACHE_001", "캐시 테스트 콘서트", "2030.09.01", "2030.09.30")
    headers = {"Authorization": f"Bearer {token}"}

    # 첫 번째 호출: KOPIS -> DB upsert
    with kopis_mock(xml):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res1 = await ac.get("/api/v1/concerts/PF_CACHE_001", headers=headers)

    # 두 번째 호출: DB
    with kopis_mock(b"", status_code=500):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res2 = await ac.get("/api/v1/concerts/PF_CACHE_001", headers=headers)

    assert res1.status_code == 200
    assert res2.status_code == 200
    assert res1.json()["id"] == res2.json()["id"]


# 존재하지 않는 공연 404 테스트
@pytest.mark.asyncio
async def test_get_concert_detail_not_found():
    token = await _get_token()
    with kopis_mock(_EMPTY_XML):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                "/api/v1/concerts/PF_NONEXISTENT_XYZ123",
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 404


# KOPIS API 오류 시 502 테스트
@pytest.mark.asyncio
async def test_get_concert_detail_kopis_502():
    token = await _get_token()
    with kopis_mock(b"", status_code=500):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                "/api/v1/concerts/PF_ERROR_XYZ999",
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 502


# _venue_candidates 테스트

# 끝의 세부관(N관) 표기를 제거한 버전과 단어 단위 접미사를 순서대로 생성하는지 테스트
def test_venue_candidates_strips_hall_suffix_and_yields_word_suffixes():
    candidates = _venue_candidates("인터파크 유니플렉스 2관")
    assert candidates[0] == "인터파크 유니플렉스 2관"
    assert "인터파크 유니플렉스" in candidates
    assert "유니플렉스" in candidates


# 빈 문자열은 빈 목록 반환
def test_venue_candidates_empty_string():
    assert _venue_candidates("") == []
    assert _venue_candidates("   ") == []


# _venue_overlaps 테스트

# 중간에 다른 단어(종합운동장)가 껴서 완전 포함 관계는 아니어도 같은 장소로 인식해야 함
def test_venue_overlaps_allows_partial_overlap_with_inserted_word():
    assert _venue_overlaps("잠실실내체육관", "잠실종합운동장 (실내체육관)") is True


# 전혀 다른 장소는 겹치지 않음 (짧은 우연의 일치로 오탐하지 않아야 함)
def test_venue_overlaps_rejects_unrelated_venues():
    assert _venue_overlaps("잠실실내체육관", "톤스튜디오 서울") is False


# 공연장 + 날짜 기준 재검색(/search-by-venue) 테스트

# 시설 검색(/prfplc)과 공연 목록(/pblprfr)을 URL로 구분하는 mock
def _venue_search_mock(facility_xml: bytes, performance_xml: bytes):
    async def _mock_get(url, **kwargs):
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.content = facility_xml if url.endswith("/prfplc") else performance_xml
        return mock_response

    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = _mock_get
    return patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client)


# 공연장명으로 시설 코드를 찾고 그 코드로 공연 목록을 조회하는지 테스트
@pytest.mark.asyncio
async def test_search_by_venue_success():
    token = await _get_token()
    facility_xml = (
        '<?xml version="1.0" encoding="UTF-8"?><dbs>'
        '<db><fcltynm>유니플렉스</fcltynm><mt10id>FC001233</mt10id></db>'
        '</dbs>'
    ).encode("utf-8")
    performance_xml = _make_kopis_xml("PF_VENUE_001", "빨래 [대학로]", "2024.06.07", "2025.03.02")

    with _venue_search_mock(facility_xml, performance_xml):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                "/api/v1/concerts/search-by-venue",
                params={
                    "venue": "인터파크 유니플렉스 2관",
                    "start_date": "2024-07-10",
                    "end_date": "2024-07-24",
                },
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 200
    data = response.json()
    assert len(data) == 1
    assert data[0]["kopis_id"] == "PF_VENUE_001"


# 시설 검색이 전부 실패하면(등록 안 된 공연장) 빈 목록 반환
@pytest.mark.asyncio
async def test_search_by_venue_no_facility_match():
    token = await _get_token()
    empty_facility_xml = b'<?xml version="1.0" encoding="UTF-8"?><dbs/>'

    with _venue_search_mock(empty_facility_xml, _EMPTY_XML):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                "/api/v1/concerts/search-by-venue",
                params={"venue": "존재하지않는공연장 XYZ"},
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 200
    assert response.json() == []
