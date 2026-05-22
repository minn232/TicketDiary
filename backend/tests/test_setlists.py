import uuid
import pytest
from unittest.mock import AsyncMock, MagicMock, patch
from httpx import AsyncClient, ASGITransport
from app.main import app
from conftest import _get_token, kopis_mock


# 헬퍼

# KOPIS 공연 정보 XML 생성
def _make_kopis_xml(kopis_id: str, artist: str = "테스트아티스트") -> bytes:
    crew = f"<prfcrew>출연: {artist}</prfcrew>" if artist else ""
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f"<dbs><db>"
        f"<mt20id>{kopis_id}</mt20id>"
        f"<prfnm>{kopis_id} 공연</prfnm>"
        f"<prfpdfrom>2030.06.01</prfpdfrom>"
        f"<prfpdto>2030.06.01</prfpdto>"
        f"<fcltynm>테스트공연장</fcltynm>"
        f'<poster>https://example.com/poster.jpg</poster>'
        f"<genrenm>팝</genrenm>"
        f"<prfstate>공연예정</prfstate>"
        f"{crew}"
        f"<pcseguidance>R석 110,000원</pcseguidance>"
        f"<sty>공연 소개</sty>"
        f"</db></dbs>"
    ).encode("utf-8")


# Setlist.fm mock

# Setlist.fm 공연 상세 정보 생성
def _make_setlistfm_detail(setlistfm_id: str, artist: str = "테스트아티스트") -> dict:
    return {
        "id": setlistfm_id,
        "eventDate": "01-06-2030",
        "artist": {"name": artist},
        "venue": {
            "name": "테스트공연장",
            "city": {"name": "서울"},
        },
        "sets": {
            "set": [
                {"song": [{"name": "노래1"}, {"name": "노래2"}]},
                {"encore": 1, "song": [{"name": "앙코르곡"}]},
            ]
        },
        "url": f"https://www.setlist.fm/setlist/test/{setlistfm_id}.html",
    }


# Setlist.fm 검색 결과 생성
def _make_setlistfm_search(setlistfm_id: str, artist: str = "테스트아티스트") -> dict:
    return {
        "type": "setlists",
        "itemsPerPage": 20,
        "page": 1,
        "total": 1,
        "setlist": [_make_setlistfm_detail(setlistfm_id, artist)],
    }


# Setlist.fm API 모킹
def _setlistfm_mock(data: dict | None = None, status_code: int = 200):
    mock_response = MagicMock()
    mock_response.status_code = status_code
    mock_response.json = MagicMock(return_value=data or {})
    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = AsyncMock(return_value=mock_response)
    return patch("app.services.setlistfm.httpx.AsyncClient", return_value=mock_client)


# 공통 헬퍼

# 공연 생성 (kopis_mock)
async def _create_concert(kopis_id: str, artist: str = "테스트아티스트") -> str:
    token = await _get_token()
    xml = _make_kopis_xml(kopis_id, artist)
    with kopis_mock(xml):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                f"/api/v1/concerts/{kopis_id}",
                headers={"Authorization": f"Bearer {token}"},
            )
    assert response.status_code == 200
    return response.json()["id"]


# 후보 검색 테스트 (GET /concerts/{concert_id}/setlist/search)

# Setlist.fm 검색 성공 테스트 (후보 구조 검증)
@pytest.mark.asyncio
async def test_search_setlists_success():
    concert_id = await _create_concert("PF_SL_SEARCH_001")
    token = await _get_token()

    search_data = _make_setlistfm_search("SF_SEARCH_001")
    with _setlistfm_mock(search_data):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                f"/api/v1/concerts/{concert_id}/setlist/search",
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 200
    data = response.json()
    assert len(data) == 1

    candidate = data[0]
    assert candidate["setlistfm_id"] == "SF_SEARCH_001"
    assert candidate["artist_name"] == "테스트아티스트"
    assert candidate["venue_name"] == "테스트공연장"
    assert candidate["city_name"] == "서울"
    assert candidate["song_count"] == 3  # 본 공연 2곡 + 앙코르 1곡
    assert candidate["songs"][0] == {"name": "노래1", "encore": False}
    assert candidate["songs"][2] == {"name": "앙코르곡", "encore": True}


# Setlist.fm 결과 없음 404 테스트
@pytest.mark.asyncio
async def test_search_setlists_empty_result():
    concert_id = await _create_concert("PF_SL_SEARCH_002")
    token = await _get_token()

    with _setlistfm_mock(status_code=404):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                f"/api/v1/concerts/{concert_id}/setlist/search",
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 200
    assert response.json() == []


# Setlist.fm API 오류 시 502 테스트
@pytest.mark.asyncio
async def test_search_setlists_api_502():
    concert_id = await _create_concert("PF_SL_SEARCH_003")
    token = await _get_token()

    with _setlistfm_mock(status_code=500):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                f"/api/v1/concerts/{concert_id}/setlist/search",
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 502


# 존재하지 않는 concert_id로 검색 시 404 테스트
@pytest.mark.asyncio
async def test_search_concert_not_found_404():
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.get(
            f"/api/v1/concerts/{uuid.uuid4()}/setlist/search",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 404


# 아티스트 정보 없는 공연 검색 시 400 테스트
@pytest.mark.asyncio
async def test_search_no_artist_400():
    # artist 없이 공연 생성 → artist_name = []
    concert_id = await _create_concert("PF_SL_NO_ARTIST", artist="")
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.get(
            f"/api/v1/concerts/{concert_id}/setlist/search",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 400


# 셋리스트 저장 테스트 (POST /concerts/{concert_id}/setlist)

# Setlist.fm ID로 셋리스트 가져와 저장 성공 테스트
@pytest.mark.asyncio
async def test_fetch_real_setlist_success():
    concert_id = await _create_concert("PF_SL_FETCH_001")
    token = await _get_token()

    detail_data = _make_setlistfm_detail("SF_FETCH_001")
    with _setlistfm_mock(detail_data):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/setlist",
                json={"setlistfm_id": "SF_FETCH_001"},
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 201
    data = response.json()
    assert data["setlistfm_id"] == "SF_FETCH_001"
    assert data["concert_id"] == concert_id
    assert data["is_user_edited"] is False
    assert len(data["songs"]) == 3
    assert data["songs"][0] == {"name": "노래1", "encore": False}
    assert data["songs"][2] == {"name": "앙코르곡", "encore": True}


# 동일 공연에 다른 setlistfm_id로 재저장 시 upsert 테스트
@pytest.mark.asyncio
async def test_fetch_real_setlist_upsert():
    concert_id = await _create_concert("PF_SL_UPSERT_001")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    with _setlistfm_mock(_make_setlistfm_detail("SF_UPSERT_001")):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res1 = await ac.post(
                f"/api/v1/concerts/{concert_id}/setlist",
                json={"setlistfm_id": "SF_UPSERT_001"},
                headers=headers,
            )

    with _setlistfm_mock(_make_setlistfm_detail("SF_UPSERT_002")):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res2 = await ac.post(
                f"/api/v1/concerts/{concert_id}/setlist",
                json={"setlistfm_id": "SF_UPSERT_002"},
                headers=headers,
            )

    # 두 번째 저장으로 덮어씌워져야 함
    assert res1.status_code == 201
    assert res2.status_code == 201
    assert res1.json()["id"] == res2.json()["id"]
    assert res2.json()["setlistfm_id"] == "SF_UPSERT_002"


# 존재하지 않는 setlistfm_id 404 테스트
@pytest.mark.asyncio
async def test_fetch_real_setlist_setlistfm_not_found_404():
    concert_id = await _create_concert("PF_SL_FETCH_002")
    token = await _get_token()

    with _setlistfm_mock(status_code=404):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/setlist",
                json={"setlistfm_id": "SF_NONEXISTENT"},
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 404


# Setlist.fm API 오류 시 502 테스트
@pytest.mark.asyncio
async def test_fetch_real_setlist_api_502():
    concert_id = await _create_concert("PF_SL_FETCH_003")
    token = await _get_token()

    with _setlistfm_mock(status_code=500):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/setlist",
                json={"setlistfm_id": "SF_ANY"},
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 502


# 셋리스트 조회 테스트 (GET /concerts/{concert_id}/setlist)

# 저장된 셋리스트 조회 성공 테스트
@pytest.mark.asyncio
async def test_get_real_setlist_success():
    concert_id = await _create_concert("PF_SL_GET_001")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    # 먼저 저장
    with _setlistfm_mock(_make_setlistfm_detail("SF_GET_001")):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.post(
                f"/api/v1/concerts/{concert_id}/setlist",
                json={"setlistfm_id": "SF_GET_001"},
                headers=headers,
            )

    # DB에서 조회
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.get(
            f"/api/v1/concerts/{concert_id}/setlist",
            headers=headers,
        )

    assert response.status_code == 200
    data = response.json()
    assert data["setlistfm_id"] == "SF_GET_001"
    assert data["concert_id"] == concert_id
    assert len(data["songs"]) == 3


# 셋리스트 없는 공연 조회 시 404 테스트
@pytest.mark.asyncio
async def test_get_real_setlist_not_found_404():
    concert_id = await _create_concert("PF_SL_GET_002")
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.get(
            f"/api/v1/concerts/{concert_id}/setlist",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 404
