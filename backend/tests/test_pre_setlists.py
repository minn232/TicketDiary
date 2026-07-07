from unittest.mock import AsyncMock, MagicMock, patch

import pytest
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


# 공연 생성 (kopis_mock)
async def _create_concert(kopis_id: str, artist: str = "테스트아티스트") -> str:
    token = await _get_token()
    with kopis_mock(_make_kopis_xml(kopis_id, artist)):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                f"/api/v1/concerts/{kopis_id}",
                headers={"Authorization": f"Bearer {token}"},
            )
    assert response.status_code == 200
    return response.json()["id"]


# Setlist.fm mock (아티스트 과거 공연 데이터)

# 여러 공연의 곡 목록 생성
def _make_artist_setlists(songs_per_concert: list[list[str]], encore_songs: list[str] | None = None) -> dict:
    setlists = []
    for i, songs in enumerate(songs_per_concert):
        sets = [{"song": [{"name": s} for s in songs]}]
        if encore_songs:
            sets.append({"encore": 1, "song": [{"name": s} for s in encore_songs]})
        setlists.append({
            "id": f"SF_ARTIST_{i:03d}",
            "eventDate": f"01-0{(i % 9) + 1}-2025",
            "artist": {"name": "테스트아티스트"},
            "venue": {"name": "테스트공연장", "city": {"name": "서울"}},
            "sets": {"set": sets},
            "url": f"https://www.setlist.fm/setlist/test/SF_ARTIST_{i:03d}.html",
        })
    return {
        "type": "setlists",
        "itemsPerPage": 20,
        "page": 1,
        "total": len(setlists),
        "setlist": setlists,
    }


# Setlist.fm 아티스트 공연 데이터 모킹
def _setlistfm_artist_mock(data: dict | None = None, status_code: int = 200):
    mock_response = MagicMock()
    mock_response.status_code = status_code
    mock_response.json = MagicMock(return_value=data or {})
    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = AsyncMock(return_value=mock_response)
    return patch("app.services.setlistfm.httpx.AsyncClient", return_value=mock_client)


# 예상 셋리스트 생성 테스트 (POST /concerts/{concert_id}/setlist/pre/generate)

# 생성 성공 테스트 + 빈도 집계 검증 테스트
@pytest.mark.asyncio
async def test_generate_pre_setlist_success():
    concert_id = await _create_concert("PF_PRE_GEN_001")
    token = await _get_token()

    # 노래A: 3회, 노래B: 2회, 노래C: 1회
    concerts_data = _make_artist_setlists([
        ["노래A", "노래B", "노래C"],
        ["노래A", "노래B"],
        ["노래A"],
    ])

    with _setlistfm_artist_mock(concerts_data):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/setlist/pre/generate",
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 201
    data = response.json()
    assert data["concert_id"] == concert_id
    assert data["is_user_edited"] is False
    # 빈도 높은 순 정렬 확인
    song_names = [s["name"] for s in data["songs"]]
    assert song_names[0] == "노래A"
    assert song_names[1] == "노래B"
    assert song_names[2] == "노래C"


# 재생성 시 upsert 테스트
@pytest.mark.asyncio
async def test_generate_pre_setlist_upsert():
    concert_id = await _create_concert("PF_PRE_GEN_003")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    data1 = _make_artist_setlists([["노래A", "노래B"]])
    data2 = _make_artist_setlists([["노래X", "노래Y", "노래Z"]])

    with _setlistfm_artist_mock(data1):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res1 = await ac.post(f"/api/v1/concerts/{concert_id}/setlist/pre/generate", headers=headers)

    with _setlistfm_artist_mock(data2):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res2 = await ac.post(f"/api/v1/concerts/{concert_id}/setlist/pre/generate", headers=headers)

    assert res1.status_code == 201
    assert res2.status_code == 201
    assert res1.json()["id"] == res2.json()["id"]
    assert [s["name"] for s in res2.json()["songs"]] == ["노래X", "노래Y", "노래Z"]


# 아티스트 정보 없는 공연 400 테스트
@pytest.mark.asyncio
async def test_generate_pre_setlist_no_artist_400():
    concert_id = await _create_concert("PF_PRE_GEN_004", artist="")
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post(
            f"/api/v1/concerts/{concert_id}/setlist/pre/generate",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 400


# Setlist.fm 데이터 없음 404 테스트
@pytest.mark.asyncio
async def test_generate_pre_setlist_no_data_404():
    concert_id = await _create_concert("PF_PRE_GEN_005")
    token = await _get_token()

    with _setlistfm_artist_mock(status_code=404):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/setlist/pre/generate",
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 404


# Setlist.fm API 오류 시 502 테스트
@pytest.mark.asyncio
async def test_generate_pre_setlist_api_502():
    concert_id = await _create_concert("PF_PRE_GEN_006")
    token = await _get_token()

    with _setlistfm_artist_mock(status_code=500):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/setlist/pre/generate",
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 502


# 예상 셋리스트 조회 테스트 (GET /concerts/{concert_id}/setlist/pre)

# 저장된 예상 셋리스트 조회 성공 테스트
@pytest.mark.asyncio
async def test_get_pre_setlist_success():
    concert_id = await _create_concert("PF_PRE_GET_001")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    concerts_data = _make_artist_setlists([["노래A", "노래B"]])
    with _setlistfm_artist_mock(concerts_data):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.post(f"/api/v1/concerts/{concert_id}/setlist/pre/generate", headers=headers)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.get(
            f"/api/v1/concerts/{concert_id}/setlist/pre",
            headers=headers,
        )

    assert response.status_code == 200
    data = response.json()
    assert data["concert_id"] == concert_id
    assert len(data["songs"]) == 2


# 예상 셋리스트 없는 공연 조회 시 404 테스트
@pytest.mark.asyncio
async def test_get_pre_setlist_not_found_404():
    concert_id = await _create_concert("PF_PRE_GET_002")
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.get(
            f"/api/v1/concerts/{concert_id}/setlist/pre",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert response.status_code == 404


# show_predicted_setlist 설정 비활성화 시 403 테스트

# 조회 비활성화 403 테스트
@pytest.mark.asyncio
async def test_get_pre_setlist_forbidden_when_setting_off():
    concert_id = await _create_concert("PF_PRE_SETTING_001")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    concerts_data = _make_artist_setlists([["노래A"]])
    with _setlistfm_artist_mock(concerts_data):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.post(f"/api/v1/concerts/{concert_id}/setlist/pre/generate", headers=headers)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch("/api/v1/settings", json={"show_predicted_setlist": False}, headers=headers)
        res = await ac.get(f"/api/v1/concerts/{concert_id}/setlist/pre", headers=headers)

    assert res.status_code == 403


# 생성 비활성화 403 테스트
@pytest.mark.asyncio
async def test_generate_pre_setlist_forbidden_when_setting_off():
    concert_id = await _create_concert("PF_PRE_SETTING_002")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch("/api/v1/settings", json={"show_predicted_setlist": False}, headers=headers)

    concerts_data = _make_artist_setlists([["노래A"]])
    with _setlistfm_artist_mock(concerts_data):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/concerts/{concert_id}/setlist/pre/generate",
                headers=headers,
            )

    assert res.status_code == 403


# 설정 다시 활성화 시 정상 조회 테스트
@pytest.mark.asyncio
async def test_get_pre_setlist_accessible_when_setting_restored():
    concert_id = await _create_concert("PF_PRE_SETTING_003")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    concerts_data = _make_artist_setlists([["노래A"]])
    with _setlistfm_artist_mock(concerts_data):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.post(f"/api/v1/concerts/{concert_id}/setlist/pre/generate", headers=headers)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch("/api/v1/settings", json={"show_predicted_setlist": False}, headers=headers)
        await ac.patch("/api/v1/settings", json={"show_predicted_setlist": True}, headers=headers)
        res = await ac.get(f"/api/v1/concerts/{concert_id}/setlist/pre", headers=headers)

    assert res.status_code == 200
