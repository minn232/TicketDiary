import uuid
from datetime import date, datetime, timedelta, timezone
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from app.core.database import AsyncSessionLocal
from app.main import app
from app.models.artist_normalization import ArtistAlias, CanonicalArtist
from app.models.concert import Concert
from app.models.setlist import RealSetlist
from app.services.lineup import upsert_concert_lineup
from app.services.setlist import (
    check_real_setlist_on_view,
    retry_real_setlist_generation,
    search_with_artist_fallbacks,
)
from conftest import _get_token, kopis_mock


# 헬퍼

# KOPIS 공연 정보 XML 생성
def _make_kopis_xml(kopis_id: str, artist: str = "테스트아티스트") -> bytes:
    cast = f"<prfcast>{artist}</prfcast>" if artist else ""
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f"<dbs><db>"
        f"<mt20id>{kopis_id}</mt20id>"
        f"<prfnm>{kopis_id} 공연</prfnm>"
        f"<prfpdfrom>2030.06.01</prfpdfrom>"
        f"<prfpdto>2030.06.01</prfpdto>"
        f"<fcltynm>테스트공연장</fcltynm>"
        f'<poster>https://example.com/poster.jpg</poster>'
        f"<genrenm>대중음악</genrenm>"
        f"<prfstate>공연예정</prfstate>"
        f"{cast}"
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


# 여러 날짜(2030.06.01~2030.06.03)에 걸친 공연 생성 - performance_date 관련 테스트용
def _make_kopis_xml_multiday(kopis_id: str, artist: str = "테스트아티스트") -> bytes:
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f"<dbs><db>"
        f"<mt20id>{kopis_id}</mt20id>"
        f"<prfnm>{kopis_id} 공연</prfnm>"
        f"<prfpdfrom>2030.06.01</prfpdfrom>"
        f"<prfpdto>2030.06.03</prfpdto>"
        f"<fcltynm>테스트공연장</fcltynm>"
        f'<poster>https://example.com/poster.jpg</poster>'
        f"<genrenm>대중음악</genrenm>"
        f"<prfstate>공연예정</prfstate>"
        f"<prfcast>{artist}</prfcast>"
        f"<pcseguidance>R석 110,000원</pcseguidance>"
        f"<sty>공연 소개</sty>"
        f"</db></dbs>"
    ).encode("utf-8")


async def _create_multiday_concert(kopis_id: str, artist: str = "테스트아티스트") -> str:
    token = await _get_token()
    xml = _make_kopis_xml_multiday(kopis_id, artist)
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
    assert candidate["songs"][0] == {"name": "노래1", "encore": False, "artist": None, "source": None}
    assert candidate["songs"][2] == {"name": "앙코르곡", "encore": True, "artist": None, "source": None}


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
    # artist 없이 공연 생성 -> artist_name = []
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
    assert data["songs"][0] == {"name": "노래1", "encore": False, "artist": None, "source": None}
    assert data["songs"][2] == {"name": "앙코르곡", "encore": True, "artist": None, "source": None}


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


# 페스티벌(아티스트 2명 이상) 실제 셋리스트 자동 생성 테스트

# 아티스트별로 다른 검색 응답을 주는 Setlist.fm 모킹. by_artist에 없는 아티스트로
# 검색하면 404(데이터 없음)로 취급.
def _setlistfm_search_mock_multi(by_artist: dict[str, dict]):
    async def _get(url, headers=None, params=None):
        mock_response = MagicMock()
        artist = (params or {}).get("artistName") or (params or {}).get("artistMbid")
        data = by_artist.get(artist)
        if data is None:
            mock_response.status_code = 404
            mock_response.json = MagicMock(return_value={})
        else:
            mock_response.status_code = 200
            mock_response.json = MagicMock(return_value=data)
        return mock_response

    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = AsyncMock(side_effect=_get)
    return patch("app.services.setlistfm.httpx.AsyncClient", return_value=mock_client)


# 아티스트 2명 각각의 실제 셋리스트를 자동 검색해서 하나로 합치는지 테스트
@pytest.mark.asyncio
async def test_generate_real_setlist_for_festival_success():
    artist_a = "우주여행자밴드"
    artist_b = "산책하는고양이"
    concert_id = await _create_concert("PF_SL_FEST_001", artist=f"{artist_a},{artist_b}")
    token = await _get_token()

    search_a = _make_setlistfm_search("SF_FEST_A", artist=artist_a)
    search_b = _make_setlistfm_search("SF_FEST_B", artist=artist_b)

    with _setlistfm_search_mock_multi({artist_a: search_a, artist_b: search_b}):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/setlist/generate-festival",
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 201
    data = response.json()
    assert data["concert_id"] == concert_id
    assert data["setlistfm_id"] is None  # 아티스트 2명 매칭돼서 단일 필드로 못 채움
    songs = data["songs"]
    a_songs = [s for s in songs if s["artist"] == artist_a]
    b_songs = [s for s in songs if s["artist"] == artist_b]
    assert len(a_songs) == 3  # _make_setlistfm_detail 기본: 본공연 2곡 + 앙코르 1곡
    assert len(b_songs) == 3


# 아티스트 한 명만 매칭돼도(나머지는 데이터 없음) 매칭된 그 한 명 기준으로 저장되고,
# setlistfm_id도 그 하나로 채워지는지 테스트
@pytest.mark.asyncio
async def test_generate_real_setlist_for_festival_partial_match():
    artist_a = "우주여행자밴드"
    artist_b = "산책하는고양이"
    concert_id = await _create_concert("PF_SL_FEST_002", artist=f"{artist_a},{artist_b}")
    token = await _get_token()

    search_a = _make_setlistfm_search("SF_FEST_PARTIAL", artist=artist_a)
    # artist_b는 by_artist에 없음 -> 404 취급

    with _setlistfm_search_mock_multi({artist_a: search_a}):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/setlist/generate-festival",
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 201
    data = response.json()
    assert data["setlistfm_id"] == "SF_FEST_PARTIAL"
    assert all(s["artist"] == artist_a for s in data["songs"])


# 어느 아티스트도 안 매칭되면 404 테스트
@pytest.mark.asyncio
async def test_generate_real_setlist_for_festival_no_match_404():
    artist_a = "우주여행자밴드"
    artist_b = "산책하는고양이"
    concert_id = await _create_concert("PF_SL_FEST_003", artist=f"{artist_a},{artist_b}")
    token = await _get_token()

    with _setlistfm_search_mock_multi({}):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/setlist/generate-festival",
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 404


# concert_lineups에 날짜별 배정이 있으면(같은 아티스트가 여러 날 아니라 날짜마다 다른
# 아티스트), 그 날짜에 배정 안 된 아티스트는 자동 생성에서 아예 검색 대상에서 빠지는지 테스트.
# artist_b도 Setlist.fm 데이터를 주지만(모킹), 배정된 아티스트가 artist_a뿐인 날짜라 결과에
# artist_b 곡이 안 섞여야 함 - 필터링이 실제로 걸린다는 증거.
@pytest.mark.asyncio
async def test_generate_real_setlist_scoped_to_date_lineup():
    artist_a = "우주여행자밴드"
    artist_b = "산책하는고양이"
    concert_id = await _create_multiday_concert("PF_SL_FEST_DATE_001", artist=f"{artist_a},{artist_b}")
    token = await _get_token()

    async with AsyncSessionLocal() as db:
        await upsert_concert_lineup(
            db, uuid.UUID(concert_id), [{"artist": artist_a, "performance_date": "2030-06-01"}], source="crawl"
        )
        await upsert_concert_lineup(
            db, uuid.UUID(concert_id), [{"artist": artist_b, "performance_date": "2030-06-02"}], source="crawl"
        )

    search_a = _make_setlistfm_search("SF_FEST_DATE_A", artist=artist_a)
    search_b = _make_setlistfm_search("SF_FEST_DATE_B", artist=artist_b)

    with _setlistfm_search_mock_multi({artist_a: search_a, artist_b: search_b}):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/setlist/generate-festival?date=2030-06-01",
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 201
    data = response.json()
    # 1명만 매칭됐다는 뜻으로 setlistfm_id가 채워짐 - artist_b까지 검색했다면 2명 매칭돼서 null이어야 함
    assert data["setlistfm_id"] == "SF_FEST_DATE_A"
    assert all(s["artist"] == artist_a for s in data["songs"])


# get_real_setlist(placeholder 응답)의 artist_names도 날짜 배정으로 좁혀지는지 테스트
@pytest.mark.asyncio
async def test_get_real_setlist_artist_names_scoped_to_date_lineup():
    artist_a = "우주여행자밴드"
    artist_b = "산책하는고양이"
    concert_id = await _create_multiday_concert("PF_SL_GET_DATE_001", artist=f"{artist_a},{artist_b}")
    token = await _get_token()

    async with AsyncSessionLocal() as db:
        await upsert_concert_lineup(
            db, uuid.UUID(concert_id), [{"artist": artist_a, "performance_date": "2030-06-01"}], source="crawl"
        )

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.get(
            f"/api/v1/concerts/{concert_id}/setlist?date=2030-06-01",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 200
    assert response.json()["artist_names"] == [artist_a]


# 이 콘서트에 배정 정보가 아예 없으면(도입 전 옛날 공연 등) 기존처럼 전체 아티스트로 폴백하는지 테스트
@pytest.mark.asyncio
async def test_get_real_setlist_artist_names_falls_back_without_lineup_data():
    artist_a = "우주여행자밴드"
    artist_b = "산책하는고양이"
    concert_id = await _create_multiday_concert("PF_SL_GET_FALLBACK_001", artist=f"{artist_a},{artist_b}")
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.get(
            f"/api/v1/concerts/{concert_id}/setlist?date=2030-06-01",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 200
    assert set(response.json()["artist_names"]) == {artist_a, artist_b}


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


# 셋리스트 없는 공연 조회 시, 404 대신 아티스트 목록만 채운 빈 응답 테스트
@pytest.mark.asyncio
async def test_get_real_setlist_not_found_returns_empty_with_artist_names():
    concert_id = await _create_concert("PF_SL_GET_002")
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.get(
            f"/api/v1/concerts/{concert_id}/setlist",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 200
    data = response.json()
    assert data["id"] is None
    assert data["songs"] == []
    assert data["artist_names"] == ["테스트아티스트"]


# performance_date 관련 테스트 (여러 날짜에 걸친 공연)

# 여러 날짜 공연에 date 없이 조회/저장하면 400 테스트
@pytest.mark.asyncio
async def test_multiday_concert_requires_date_query_param():
    concert_id = await _create_multiday_concert("PF_SL_MULTI_NODATE")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        get_res = await ac.get(f"/api/v1/concerts/{concert_id}/setlist", headers=headers)
        post_res = await ac.post(
            f"/api/v1/concerts/{concert_id}/setlist",
            json={"setlistfm_id": "SF_ANY"},
            headers=headers,
        )

    assert get_res.status_code == 400
    assert post_res.status_code == 400


# 같은 공연, 다른 날짜(date 쿼리파라미터)로 저장하면 서로 다른(독립적인) 셋리스트로 저장되는지 테스트
@pytest.mark.asyncio
async def test_multiday_concert_different_dates_have_independent_setlists():
    concert_id = await _create_multiday_concert("PF_SL_MULTI_DATES")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    with _setlistfm_mock(_make_setlistfm_detail("SF_DAY1")):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            day1_res = await ac.post(
                f"/api/v1/concerts/{concert_id}/setlist?date=2030-06-01",
                json={"setlistfm_id": "SF_DAY1"},
                headers=headers,
            )

    with _setlistfm_mock(_make_setlistfm_detail("SF_DAY2")):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            day2_res = await ac.post(
                f"/api/v1/concerts/{concert_id}/setlist?date=2030-06-02",
                json={"setlistfm_id": "SF_DAY2"},
                headers=headers,
            )

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        day1_get = await ac.get(f"/api/v1/concerts/{concert_id}/setlist?date=2030-06-01", headers=headers)
        day2_get = await ac.get(f"/api/v1/concerts/{concert_id}/setlist?date=2030-06-02", headers=headers)

    assert day1_res.status_code == 201
    assert day2_res.status_code == 201
    assert day1_res.json()["id"] != day2_res.json()["id"]
    assert day1_get.json()["setlistfm_id"] == "SF_DAY1"
    assert day2_get.json()["setlistfm_id"] == "SF_DAY2"
    assert day1_get.json()["performance_date"] == "2030-06-01"
    assert day2_get.json()["performance_date"] == "2030-06-02"


# 하루짜리 공연은 date 쿼리파라미터 없이도 자동으로 그 날짜로 결정되는지 테스트
@pytest.mark.asyncio
async def test_single_day_concert_performance_date_auto_resolved():
    concert_id = await _create_concert("PF_SL_SINGLEDATE")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    with _setlistfm_mock(_make_setlistfm_detail("SF_SINGLE")):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/setlist",
                json={"setlistfm_id": "SF_SINGLE"},
                headers=headers,
            )

    assert response.status_code == 201
    assert response.json()["performance_date"] == "2030-06-01"


# 티켓 기준 페스티벌 실제 셋리스트 자동 생성 라우트 테스트
@pytest.mark.asyncio
async def test_ticket_generate_real_setlist_for_festival():
    artist_a = "우주여행자밴드"
    artist_b = "산책하는고양이"
    concert_id = await _create_concert("PF_SL_TICKET_FEST_001", artist=f"{artist_a},{artist_b}")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        ticket_res = await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)
    ticket_id = ticket_res.json()["id"]

    search_a = _make_setlistfm_search("SF_TICKET_FEST_A", artist=artist_a)
    search_b = _make_setlistfm_search("SF_TICKET_FEST_B", artist=artist_b)

    with _setlistfm_search_mock_multi({artist_a: search_a, artist_b: search_b}):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/tickets/{ticket_id}/setlist/generate-festival",
                headers=headers,
            )

    assert response.status_code == 201
    songs = response.json()["songs"]
    assert {s["artist"] for s in songs} == {artist_a, artist_b}


# 티켓 기준 셋리스트 라우트 테스트 (GET/POST /tickets/{ticket_id}/setlist)

# 하루짜리 공연 티켓은 attended_date 없이도 티켓 라우트로 조회/저장 가능한지 테스트
@pytest.mark.asyncio
async def test_ticket_setlist_route_single_day_works_without_attended_date():
    concert_id = await _create_concert("PF_SL_TICKET_SINGLE")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        ticket_res = await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)
    ticket_id = ticket_res.json()["id"]

    with _setlistfm_mock(_make_setlistfm_detail("SF_TICKET_SINGLE")):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            post_res = await ac.post(
                f"/api/v1/tickets/{ticket_id}/setlist",
                json={"setlistfm_id": "SF_TICKET_SINGLE"},
                headers=headers,
            )

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        get_res = await ac.get(f"/api/v1/tickets/{ticket_id}/setlist", headers=headers)

    assert post_res.status_code == 201
    assert get_res.status_code == 200
    assert get_res.json()["setlistfm_id"] == "SF_TICKET_SINGLE"


# 여러 날짜 공연 티켓은 attended_date가 있으면 그 날짜의 셋리스트를 자동으로 가리키는지 테스트
@pytest.mark.asyncio
async def test_ticket_setlist_route_uses_attended_date_for_multiday_concert():
    concert_id = await _create_multiday_concert("PF_SL_TICKET_MULTI")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        ticket_res = await ac.post(
            "/api/v1/tickets",
            json={"concert_id": concert_id, "attended_date": "2030-06-02"},
            headers=headers,
        )
    ticket_id = ticket_res.json()["id"]

    # 콘서트 기준 라우트로 2일차(06-02) 셋리스트를 미리 저장
    with _setlistfm_mock(_make_setlistfm_detail("SF_DAY2_TICKET")):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.post(
                f"/api/v1/concerts/{concert_id}/setlist?date=2030-06-02",
                json={"setlistfm_id": "SF_DAY2_TICKET"},
                headers=headers,
            )

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        ticket_get = await ac.get(f"/api/v1/tickets/{ticket_id}/setlist", headers=headers)

    assert ticket_get.status_code == 200
    assert ticket_get.json()["setlistfm_id"] == "SF_DAY2_TICKET"
    assert ticket_get.json()["performance_date"] == "2030-06-02"


# 여러 날짜 공연인데 attended_date 없는 티켓으로 조회하면 400 테스트 (어느 날짜인지 알 수 없음)
@pytest.mark.asyncio
async def test_ticket_setlist_route_without_attended_date_on_multiday_concert_400():
    concert_id = await _create_multiday_concert("PF_SL_TICKET_NODATE")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        ticket_res = await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)
    ticket_id = ticket_res.json()["id"]

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.get(f"/api/v1/tickets/{ticket_id}/setlist", headers=headers)

    assert response.status_code == 400


# 실제 셋리스트 자동 채움 백필 잡(retry_real_setlist_generation) 테스트.
# _create_concert가 KOPIS mock으로 항상 미래(2030.06.01) 날짜로 만드니, 여기서는 직접 DB에서
# start_date/end_date를 원하는 시점으로 옮겨서 "이미 끝난 공연"을 재현함.
async def _set_concert_dates(concert_id: str, start: datetime, end: datetime) -> None:
    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Concert).where(Concert.id == uuid.UUID(concert_id)))
        concert = result.scalar_one()
        concert.start_date = start
        concert.end_date = end
        await db.commit()


async def _get_real_setlist_row(concert_id: str, performance_date) -> RealSetlist | None:
    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(RealSetlist).where(
                RealSetlist.concert_id == uuid.UUID(concert_id),
                RealSetlist.performance_date == performance_date,
            )
        )
        return result.scalar_one_or_none()


async def _get_concert_row(concert_id: str) -> Concert:
    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Concert).where(Concert.id == uuid.UUID(concert_id)))
        return result.scalar_one()


# 티켓 등록된, 3일 전에 끝난(=14일 창 안) 공연은 자동으로 채워지는지 테스트
@pytest.mark.asyncio
async def test_retry_real_setlist_generation_backfills_within_window():
    artist = "테스트아티스트"
    concert_id = await _create_concert("PF_SL_BACKFILL_001", artist=artist)
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    show_date = (datetime.now(timezone.utc) - timedelta(days=3)).date()
    show_dt = datetime.combine(show_date, datetime.min.time(), tzinfo=timezone.utc)
    await _set_concert_dates(concert_id, show_dt, show_dt)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)

    search_data = _make_setlistfm_search("SF_BACKFILL_001", artist=artist)
    with _setlistfm_search_mock_multi({artist: search_data}):
        await retry_real_setlist_generation()

    row = await _get_real_setlist_row(concert_id, show_date)
    assert row is not None
    assert len(row.songs) == 3  # 본공연 2곡 + 앙코르 1곡


# 20일 전에 끝난(=14일 창 밖) 공연은 시도조차 안 하는지 테스트
@pytest.mark.asyncio
async def test_retry_real_setlist_generation_skips_after_window():
    artist = "테스트아티스트"
    concert_id = await _create_concert("PF_SL_BACKFILL_002", artist=artist)
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    show_date = (datetime.now(timezone.utc) - timedelta(days=20)).date()
    show_dt = datetime.combine(show_date, datetime.min.time(), tzinfo=timezone.utc)
    await _set_concert_dates(concert_id, show_dt, show_dt)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)

    search_data = _make_setlistfm_search("SF_BACKFILL_002", artist=artist)
    with _setlistfm_search_mock_multi({artist: search_data}):
        await retry_real_setlist_generation()

    row = await _get_real_setlist_row(concert_id, show_date)
    assert row is None


# 아무도 티켓을 등록하지 않은 공연은 대상에서 빠지는지 테스트
@pytest.mark.asyncio
async def test_retry_real_setlist_generation_skips_without_ticket():
    artist = "테스트아티스트"
    concert_id = await _create_concert("PF_SL_BACKFILL_003", artist=artist)

    show_date = (datetime.now(timezone.utc) - timedelta(days=3)).date()
    show_dt = datetime.combine(show_date, datetime.min.time(), tzinfo=timezone.utc)
    await _set_concert_dates(concert_id, show_dt, show_dt)
    # 티켓 등록 없음

    search_data = _make_setlistfm_search("SF_BACKFILL_003", artist=artist)
    with _setlistfm_search_mock_multi({artist: search_data}):
        await retry_real_setlist_generation()

    row = await _get_real_setlist_row(concert_id, show_date)
    assert row is None


# 이미 채워진 (concert_id, date)는 재시도하지 않고 그대로 두는지 테스트
@pytest.mark.asyncio
async def test_retry_real_setlist_generation_skips_already_filled():
    artist = "테스트아티스트"
    concert_id = await _create_concert("PF_SL_BACKFILL_004", artist=artist)
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    show_date = (datetime.now(timezone.utc) - timedelta(days=3)).date()
    show_dt = datetime.combine(show_date, datetime.min.time(), tzinfo=timezone.utc)
    await _set_concert_dates(concert_id, show_dt, show_dt)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)

    # 미리 직접 채워둠
    async with AsyncSessionLocal() as db:
        db.add(
            RealSetlist(
                concert_id=uuid.UUID(concert_id),
                performance_date=show_date,
                songs=[{"name": "이미있는곡", "encore": False}],
            )
        )
        await db.commit()

    # 이 mock이 실제로 호출되면(=재시도했다는 뜻) 곡 수가 바뀌어야 하므로, 호출 여부를
    # 곡 내용이 그대로인지로 검증
    search_data = _make_setlistfm_search("SF_BACKFILL_004", artist=artist)
    with _setlistfm_search_mock_multi({artist: search_data}):
        await retry_real_setlist_generation()

    row = await _get_real_setlist_row(concert_id, show_date)
    assert row is not None
    assert [s["name"] for s in row.songs] == ["이미있는곡"]


# ---- 조회 시점 실제 셋리스트 확인 (check_real_setlist_on_view) ----
# 자동 백필(14일 창)을 놓친 공연도, 사용자가 "공연 후" 화면을 열 때마다(티켓 기준 실제
# 셋리스트 GET) 비어있으면 백그라운드로 한 번 더 채워보기를 시도하는 기능.

# 실제 셋리스트가 없는 티켓을 조회하면(GET) 화면엔 빈 채로 응답하고, 백그라운드로 채워져서
# DB엔 다음 조회 시점엔 반영돼있는지 테스트
@pytest.mark.asyncio
async def test_get_ticket_setlist_triggers_background_fill_when_empty():
    artist = "테스트아티스트"
    concert_id = await _create_concert("PF_SL_VIEWCHECK_001", artist=artist)
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        ticket_res = await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)
    ticket_id = ticket_res.json()["id"]

    search_data = _make_setlistfm_search("SF_VIEWCHECK_001", artist=artist)
    with _setlistfm_search_mock_multi({artist: search_data}):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            get_res = await ac.get(f"/api/v1/tickets/{ticket_id}/setlist", headers=headers)

    # 이번 응답 자체는 비어있음 - 백그라운드 결과를 기다리지 않고 바로 응답하므로
    assert get_res.status_code == 200
    assert get_res.json()["songs"] == []

    # 백그라운드로 채워졌는지 DB에서 확인(다음 조회부터 반영됨)
    performance_date = date.fromisoformat(get_res.json()["performance_date"])
    row = await _get_real_setlist_row(concert_id, performance_date)
    assert row is not None
    assert len(row.songs) == 3  # 본공연 2곡 + 앙코르 1곡
    assert row.attempted_at is not None


# 검색해도 못 찾으면 songs=[]인 빈 행이라도 남겨서 attempted_at(쿨다운 시작점)을 기록하는지 테스트
@pytest.mark.asyncio
async def test_get_ticket_setlist_records_attempt_when_not_found():
    artist = "테스트아티스트"
    concert_id = await _create_concert("PF_SL_VIEWCHECK_002", artist=artist)
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        ticket_res = await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)
    ticket_id = ticket_res.json()["id"]

    with _setlistfm_search_mock_multi({}):  # 아무 아티스트도 못 찾음
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            get_res = await ac.get(f"/api/v1/tickets/{ticket_id}/setlist", headers=headers)

    performance_date = date.fromisoformat(get_res.json()["performance_date"])
    row = await _get_real_setlist_row(concert_id, performance_date)
    assert row is not None
    assert row.songs == []
    assert row.attempted_at is not None


# 하루 쿨다운 안에는(직전 시도가 최근이면) 재시도 자체를 안 하는지 테스트 - 검색 mock이
# 실제 곡을 주더라도 쿨다운 중이면 반영되면 안 됨
@pytest.mark.asyncio
async def test_get_ticket_setlist_skips_retry_within_cooldown():
    artist = "테스트아티스트"
    concert_id = await _create_concert("PF_SL_VIEWCHECK_003", artist=artist)
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        ticket_res = await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)
    ticket_id = ticket_res.json()["id"]
    ticket_res_json = ticket_res.json()

    concert = await _get_concert_row(concert_id)
    performance_date = concert.start_date.date()

    # 방금(10분 전) 시도했지만 못 찾았던 것으로 미리 기록해둠 - 하루 쿨다운 안
    async with AsyncSessionLocal() as db:
        db.add(
            RealSetlist(
                concert_id=uuid.UUID(concert_id),
                performance_date=performance_date,
                songs=[],
                attempted_at=datetime.now(timezone.utc) - timedelta(minutes=10),
            )
        )
        await db.commit()

    # mock은 성공 데이터를 주지만, 쿨다운 중이라 호출 자체가 안 되고 여전히 빈 채여야 함
    search_data = _make_setlistfm_search("SF_VIEWCHECK_003", artist=artist)
    with _setlistfm_search_mock_multi({artist: search_data}):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.get(f"/api/v1/tickets/{ticket_id}/setlist", headers=headers)

    row = await _get_real_setlist_row(concert_id, performance_date)
    assert row.songs == []


# 유저가 직접 편집해서 빈 채로 확정한 셋리스트는(is_user_edited=True) 쿨다운과 무관하게
# 절대 자동으로 덮어쓰지 않는지 테스트
@pytest.mark.asyncio
async def test_get_ticket_setlist_never_overwrites_user_edited_empty_setlist():
    artist = "테스트아티스트"
    concert_id = await _create_concert("PF_SL_VIEWCHECK_004", artist=artist)
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        ticket_res = await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)
    ticket_id = ticket_res.json()["id"]

    concert = await _get_concert_row(concert_id)
    performance_date = concert.start_date.date()

    async with AsyncSessionLocal() as db:
        db.add(
            RealSetlist(
                concert_id=uuid.UUID(concert_id),
                performance_date=performance_date,
                songs=[],
                is_user_edited=True,
                edited_user_nickname="테스트유저",
                attempted_at=datetime.now(timezone.utc) - timedelta(days=10),  # 쿨다운은 지났어도
            )
        )
        await db.commit()

    search_data = _make_setlistfm_search("SF_VIEWCHECK_004", artist=artist)
    with _setlistfm_search_mock_multi({artist: search_data}):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.get(f"/api/v1/tickets/{ticket_id}/setlist", headers=headers)

    row = await _get_real_setlist_row(concert_id, performance_date)
    assert row.songs == []
    assert row.is_user_edited is True


# ---- Setlist.fm 검색 별칭 폴백 ----
# 콘서트에 저장된 원어 표기(예: 한자/가나)로는 Setlist.fm 검색이 0건이어도, 우리 DB에
# 이미 저장된 MusicBrainz 별칭(예: 로마자 표기)으로 재시도하면 찾을 수 있는 실제 사례
# ("ずっと真夜中でいいのに。" -> Setlist.fm엔 "ZUTOMAYO"로만 검색됨) 대응 테스트.

# 원어 표기로 검색하면 0건이지만 별칭으로 재시도하면 찾아지는지 테스트
@pytest.mark.asyncio
async def test_generate_real_setlist_falls_back_to_known_alias():
    original_name = "원어아티스트"
    alias_name = "ROMANIZED"
    concert_id = await _create_concert("PF_SL_ALIAS_001", artist=original_name)
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncSessionLocal() as db:
        canonical = CanonicalArtist(mbid="mbid-alias-test", canonical_name=original_name)
        db.add(canonical)
        await db.flush()
        db.add(ArtistAlias(canonical_artist_id=canonical.id, alias_text=alias_name, source="musicbrainz"))
        await db.commit()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        ticket_res = await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)
    ticket_id = ticket_res.json()["id"]

    # 원어 표기는 mock에 아예 등록 안 해서 404(0건), 별칭으로만 결과가 나오게 함
    search_data = _make_setlistfm_search("SF_ALIAS_001", artist=alias_name)
    search_data["setlist"][0]["artist"]["mbid"] = "mbid-alias-test"
    with _setlistfm_search_mock_multi({alias_name: search_data}):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            get_res = await ac.get(f"/api/v1/tickets/{ticket_id}/setlist", headers=headers)

    performance_date = date.fromisoformat(get_res.json()["performance_date"])
    row = await _get_real_setlist_row(concert_id, performance_date)
    assert row is not None
    assert len(row.songs) == 3


# canonical mbid가 있으면 이름이 같아도 mbid가 다른 아티스트(본명이 같은 다른 사람) 셋리는 안 씀
@pytest.mark.asyncio
async def test_generate_real_setlist_filters_same_name_other_mbid():
    artist = "동명이인가수R"
    concert_id = await _create_concert("PF_SL_MBID_001", artist=artist)
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncSessionLocal() as db:
        db.add(CanonicalArtist(mbid="mbid-real-ours", canonical_name=artist))
        await db.commit()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        ticket_res = await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)
    ticket_id = ticket_res.json()["id"]

    search_data = _make_setlistfm_search("SF_MBID_OTHER", artist=artist)
    search_data["setlist"][0]["artist"]["mbid"] = "mbid-real-other"
    with _setlistfm_search_mock_multi({artist: search_data}):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            get_res = await ac.get(f"/api/v1/tickets/{ticket_id}/setlist", headers=headers)

    performance_date = date.fromisoformat(get_res.json()["performance_date"])
    row = await _get_real_setlist_row(concert_id, performance_date)
    assert row is not None
    assert row.songs == []


# 검색 순서: canonical mbid → 원래 표기 → 별칭, 결과가 나오면 거기서 멈춤
@pytest.mark.asyncio
async def test_search_with_artist_fallbacks_order():
    async with AsyncSessionLocal() as db:
        canonical = CanonicalArtist(mbid="mbid-order-test", canonical_name="순서테스트가수")
        db.add(canonical)
        await db.flush()
        db.add(ArtistAlias(canonical_artist_id=canonical.id, alias_text="ORDER TEST", source="musicbrainz"))
        db.add(ArtistAlias(canonical_artist_id=canonical.id, alias_text="ORDER TEST 2", source="musicbrainz"))
        await db.commit()

    calls = []

    async def _search(query, artist_mbid, by_mbid):
        calls.append((query, artist_mbid, by_mbid))
        return [{"hit": query}] if query == "ORDER TEST" else []

    async with AsyncSessionLocal() as db:
        results = await search_with_artist_fallbacks(db, "순서테스트가수", _search)

    assert results == [{"hit": "ORDER TEST"}]
    assert calls == [
        ("순서테스트가수", "mbid-order-test", True),
        ("순서테스트가수", "mbid-order-test", False),
        ("ORDER TEST", "mbid-order-test", False),
    ]


# canonical이 없으면 mbid 검색 없이 원래 표기로만 한 번 검색
@pytest.mark.asyncio
async def test_search_with_artist_fallbacks_without_canonical():
    calls = []

    async def _search(query, artist_mbid, by_mbid):
        calls.append((query, artist_mbid, by_mbid))
        return []

    async with AsyncSessionLocal() as db:
        results = await search_with_artist_fallbacks(db, "정규화안된가수", _search)

    assert results == []
    assert calls == [("정규화안된가수", None, False)]


# 한글 표기로는 Setlist.fm 0건인 해외 아티스트도 canonical mbid로 실제 셋리가 채워지는지
@pytest.mark.asyncio
async def test_generate_real_setlist_finds_by_mbid_when_name_search_empty():
    artist = "한글표기해외가수R"
    concert_id = await _create_concert("PF_SL_BYMBID_001", artist=artist)
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncSessionLocal() as db:
        db.add(CanonicalArtist(mbid="mbid-real-bymbid", canonical_name=artist))
        await db.commit()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        ticket_res = await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)
    ticket_id = ticket_res.json()["id"]

    search_data = _make_setlistfm_search("SF_BYMBID_001", artist="Overseas Artist R")
    search_data["setlist"][0]["artist"]["mbid"] = "mbid-real-bymbid"
    with _setlistfm_search_mock_multi({"mbid-real-bymbid": search_data}):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            get_res = await ac.get(f"/api/v1/tickets/{ticket_id}/setlist", headers=headers)

    performance_date = date.fromisoformat(get_res.json()["performance_date"])
    row = await _get_real_setlist_row(concert_id, performance_date)
    assert row is not None
    assert row.setlistfm_id == "SF_BYMBID_001"
    assert len(row.songs) == 3


# 원어 표기와 별칭 둘 다 못 찾으면 그냥 빈 채로(예외 없이) 남는지 테스트
@pytest.mark.asyncio
async def test_generate_real_setlist_alias_fallback_still_not_found():
    original_name = "원어아티스트2"
    alias_name = "ROMANIZED2"
    concert_id = await _create_concert("PF_SL_ALIAS_002", artist=original_name)
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncSessionLocal() as db:
        canonical = CanonicalArtist(mbid="mbid-alias-test-2", canonical_name=original_name)
        db.add(canonical)
        await db.flush()
        db.add(ArtistAlias(canonical_artist_id=canonical.id, alias_text=alias_name, source="musicbrainz"))
        await db.commit()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        ticket_res = await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)
    ticket_id = ticket_res.json()["id"]

    with _setlistfm_search_mock_multi({}):  # 원어/별칭 둘 다 못 찾음
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            get_res = await ac.get(f"/api/v1/tickets/{ticket_id}/setlist", headers=headers)

    assert get_res.status_code == 200
    assert get_res.json()["songs"] == []
    performance_date = date.fromisoformat(get_res.json()["performance_date"])
    row = await _get_real_setlist_row(concert_id, performance_date)
    assert row is not None
    assert row.songs == []
    assert row.attempted_at is not None


# Setlist.fm API 자체가 일시 실패(5xx/레이트리밋 등)하면 "못 찾음"과 달리 쿨다운을
# 기록하지 않아서, 바로 다음 조회 때 다시 시도되는지 테스트 - music_link 캐싱에서
# API 에러를 "못 찾음"으로 캐싱해버렸던 것과 같은 종류의 버그 재발 방지
@pytest.mark.asyncio
async def test_get_ticket_setlist_transient_api_error_does_not_burn_cooldown():
    artist = "테스트아티스트"
    concert_id = await _create_concert("PF_SL_VIEWCHECK_005", artist=artist)
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        ticket_res = await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)
    ticket_id = ticket_res.json()["id"]

    # Setlist.fm이 500(우리 쪽에선 502)을 주는 상황
    with _setlistfm_mock(status_code=500):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            get_res = await ac.get(f"/api/v1/tickets/{ticket_id}/setlist", headers=headers)

    assert get_res.status_code == 200
    assert get_res.json()["songs"] == []
    performance_date = date.fromisoformat(get_res.json()["performance_date"])
    # 쿨다운용 빈 행 자체를 남기지 않아야 함(진짜 "못 찾음"이 아니므로)
    row = await _get_real_setlist_row(concert_id, performance_date)
    assert row is None

    # 쿨다운이 없으니 바로 다음 조회에서 다시 시도되고, 이번엔 정상 응답이면 채워져야 함
    search_data = _make_setlistfm_search("SF_VIEWCHECK_005", artist=artist)
    with _setlistfm_search_mock_multi({artist: search_data}):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.get(f"/api/v1/tickets/{ticket_id}/setlist", headers=headers)

    row = await _get_real_setlist_row(concert_id, performance_date)
    assert row is not None
    assert len(row.songs) == 3
