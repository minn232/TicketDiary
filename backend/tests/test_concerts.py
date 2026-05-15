import pytest
from unittest.mock import AsyncMock, MagicMock, patch
from httpx import AsyncClient, ASGITransport
from app.main import app


# KOPIS 가짜 API
def _make_kopis_xml(kopis_id: str, name: str, start: str, end: str, artist: str = "") -> bytes:
    crew = f"<prfcrew>출연: {artist}</prfcrew>" if artist else ""
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
        f"<sty>공연 소개</sty>"
        f"</db></dbs>"
    ).encode("utf-8")


# 빈 XML 응답 (검색 결과 없음)
_EMPTY_XML = b'<?xml version="1.0" encoding="UTF-8"?><dbs></dbs>'


# httpx.AsyncClient 모킹
def _httpx_mock(content: bytes, status_code: int = 200):
    mock_response = MagicMock()
    mock_response.status_code = status_code
    mock_response.content = content
    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = AsyncMock(return_value=mock_response)
    return patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client)


# ── 공연 검색 테스트 ───────────────────────────────────────────────────────────

# KOPIS 검색 성공 테스트
@pytest.mark.asyncio
async def test_search_concerts_success():
    xml = _make_kopis_xml("PF_SEARCH_001", "테스트 콘서트", "2030.06.01", "2030.06.30", "테스트아티스트")
    with _httpx_mock(xml):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get("/api/v1/concerts/search", params={"keyword": "테스트"})

    assert response.status_code == 200
    data = response.json()
    assert len(data) == 1
    assert data[0]["kopis_id"] == "PF_SEARCH_001"
    assert data[0]["name"] == "테스트 콘서트"


# 검색 결과 없음 테스트
@pytest.mark.asyncio
async def test_search_concerts_empty_result():
    with _httpx_mock(_EMPTY_XML):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get("/api/v1/concerts/search", params={"keyword": "없는공연xyz"})

    assert response.status_code == 200
    assert response.json() == []


# KOPIS API 오류 시 502 반환 테스트
@pytest.mark.asyncio
async def test_search_concerts_kopis_502():
    with _httpx_mock(b"", status_code=500):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get("/api/v1/concerts/search", params={"keyword": "테스트"})

    assert response.status_code == 502


# 동일 공연 중복 검색 시 같은 ID 반환 테스트
@pytest.mark.asyncio
async def test_search_concerts_upsert_same_id():
    xml = _make_kopis_xml("PF_UPSERT_001", "업서트 테스트", "2030.07.01", "2030.07.31")
    with _httpx_mock(xml):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res1 = await ac.get("/api/v1/concerts/search", params={"keyword": "업서트"})
            res2 = await ac.get("/api/v1/concerts/search", params={"keyword": "업서트"})

    assert res1.json()[0]["id"] == res2.json()[0]["id"]


# ── 공연 상세 조회 테스트 ─────────────────────────────────────────────────────

# KOPIS에서 상세 조회 성공 테스트
@pytest.mark.asyncio
async def test_get_concert_detail_from_kopis():
    xml = _make_kopis_xml("PF_DETAIL_001", "상세 테스트 콘서트", "2030.08.01", "2030.08.31", "아티스트A")
    with _httpx_mock(xml):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get("/api/v1/concerts/PF_DETAIL_001")

    assert response.status_code == 200
    data = response.json()
    assert data["kopis_id"] == "PF_DETAIL_001"
    assert data["name"] == "상세 테스트 콘서트"
    assert "아티스트A" in data["artist_name"]
    assert data["price"] == [
        {"seat_type": "VIP석", "price": 150000},
        {"seat_type": "R석", "price": 110000},
    ]


# DB 조회 테스트
@pytest.mark.asyncio
async def test_get_concert_detail_db_cache():
    xml = _make_kopis_xml("PF_CACHE_001", "캐시 테스트 콘서트", "2030.09.01", "2030.09.30")

    # 첫 번째 호출: KOPIS -> DB upsert
    with _httpx_mock(xml):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res1 = await ac.get("/api/v1/concerts/PF_CACHE_001")

    # 두 번째 호출: DB
    with _httpx_mock(b"", status_code=500):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res2 = await ac.get("/api/v1/concerts/PF_CACHE_001")

    assert res1.status_code == 200
    assert res2.status_code == 200
    assert res1.json()["id"] == res2.json()["id"]


# 존재하지 않는 공연 404 테스트
@pytest.mark.asyncio
async def test_get_concert_detail_not_found():
    with _httpx_mock(_EMPTY_XML):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get("/api/v1/concerts/PF_NONEXISTENT_XYZ123")

    assert response.status_code == 404


# KOPIS API 오류 시 502 테스트
@pytest.mark.asyncio
async def test_get_concert_detail_kopis_502():
    with _httpx_mock(b"", status_code=500):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get("/api/v1/concerts/PF_ERROR_XYZ999")

    assert response.status_code == 502
