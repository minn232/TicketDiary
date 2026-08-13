from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from httpx import AsyncClient, ASGITransport

from app.main import app
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
def _make_artist_setlists(
    songs_per_concert: list[list[str]],
    encore_songs: list[str] | None = None,
    artist: str = "테스트아티스트",
) -> dict:
    setlists = []
    for i, songs in enumerate(songs_per_concert):
        sets = [{"song": [{"name": s} for s in songs]}]
        if encore_songs:
            sets.append({"encore": 1, "song": [{"name": s} for s in encore_songs]})
        setlists.append({
            "id": f"SF_ARTIST_{i:03d}",
            "eventDate": f"01-0{(i % 9) + 1}-2025",
            "artist": {"name": artist},
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


# 페스티벌(아티스트 2명 이상) 예상 셋리스트 테스트

# 아티스트별로 다른 응답을 주는 Setlist.fm 모킹. by_artist에 없는 아티스트로 검색하면
# 404(데이터 없음)로 취급 - "아티스트 하나만 데이터 없어도 나머지로 계속 진행"하는
# 로직을 검증할 때 씀.
def _setlistfm_artist_mock_multi(by_artist: dict[str, dict]):
    async def _get(url, headers=None, params=None):
        mock_response = MagicMock()
        artist = (params or {}).get("artistName")
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


# 아티스트 2명 각각 top_n(단독 공연과 동일한 기본 20곡 한도)만큼 뽑혀서 artist 태그와 함께
# 합쳐지는지 테스트. 페스티벌이라고 곡 수를 줄이지 않음 - 프론트가 필요한 만큼(예: 미리보기 3곡)
# 만 잘라 쓰도록 넉넉히 다 보냄.
@pytest.mark.asyncio
async def test_generate_pre_setlist_festival_uses_all_artists():
    artist_a = "우주여행자밴드"
    artist_b = "산책하는고양이"
    concert_id = await _create_concert("PF_PRE_FEST_001", artist=f"{artist_a},{artist_b}")
    token = await _get_token()

    data_a = _make_artist_setlists([["에이곡1", "에이곡2", "에이곡3", "에이곡4"]], artist=artist_a)
    data_b = _make_artist_setlists([["비곡1", "비곡2"]], artist=artist_b)

    with _setlistfm_artist_mock_multi({artist_a: data_a, artist_b: data_b}):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/setlist/pre/generate",
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 201
    songs = response.json()["songs"]
    a_songs = [s for s in songs if s["artist"] == artist_a]
    b_songs = [s for s in songs if s["artist"] == artist_b]
    assert len(a_songs) == 4  # top_n(20) 한도 내라 데이터 4곡 전부
    assert len(b_songs) == 2  # 데이터가 2곡뿐이라 그만큼만
    assert {s["name"] for s in a_songs} == {"에이곡1", "에이곡2", "에이곡3", "에이곡4"}
    assert {s["name"] for s in b_songs} == {"비곡1", "비곡2"}


# 페스티벌에서 아티스트 한 명만 Setlist.fm에 데이터 없어도, 그 아티스트만 스킵하고
# 나머지는 정상 생성되는지 테스트(전체가 404로 실패하면 안 됨)
@pytest.mark.asyncio
async def test_generate_pre_setlist_festival_partial_artist_data_missing():
    artist_a = "우주여행자밴드"
    artist_b = "산책하는고양이"
    concert_id = await _create_concert("PF_PRE_FEST_002", artist=f"{artist_a},{artist_b}")
    token = await _get_token()

    data_a = _make_artist_setlists([["에이곡1"]], artist=artist_a)
    # artist_b는 by_artist에 아예 없음 -> 404 취급

    with _setlistfm_artist_mock_multi({artist_a: data_a}):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/setlist/pre/generate",
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 201
    songs = response.json()["songs"]
    assert {s["name"] for s in songs} == {"에이곡1"}
    assert songs[0]["artist"] == artist_a


# 아티스트가 1명뿐이면(단독 공연) 기존과 완전히 동일하게 동작(artist 태그 없음, top_n=20) 테스트
@pytest.mark.asyncio
async def test_generate_pre_setlist_solo_artist_unaffected_by_festival_logic():
    concert_id = await _create_concert("PF_PRE_SOLO_001")
    token = await _get_token()

    concerts_data = _make_artist_setlists([["노래A", "노래B", "노래C"]])
    with _setlistfm_artist_mock(concerts_data):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.post(
                f"/api/v1/concerts/{concert_id}/setlist/pre/generate",
                headers={"Authorization": f"Bearer {token}"},
            )

    assert response.status_code == 201
    songs = response.json()["songs"]
    assert all(s["artist"] is None for s in songs)


# 티켓 등록 시 자동 생성 테스트 (POST /tickets -> generate_pre_setlist_background)

# 아티스트 정보 있는 공연에 티켓 등록하면 예상 셋리스트가 자동으로 생성되는지 테스트
@pytest.mark.asyncio
async def test_ticket_registration_auto_generates_pre_setlist():
    concert_id = await _create_concert("PF_PRE_AUTO_001")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    concerts_data = _make_artist_setlists([["노래A", "노래B"]])
    with _setlistfm_artist_mock(concerts_data):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                "/api/v1/tickets", json={"concert_id": concert_id}, headers=headers
            )
    assert res.status_code == 201

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        pre_res = await ac.get(f"/api/v1/concerts/{concert_id}/setlist/pre", headers=headers)

    assert pre_res.status_code == 200
    assert pre_res.json()["concert_id"] == concert_id
    song_names = [s["name"] for s in pre_res.json()["songs"]]
    assert "노래A" in song_names


# 아티스트 정보 없는 공연은 티켓 등록해도(자동 생성 시도가 조용히 스킵돼) 예상
# 셋리스트가 안 만들어지고, 티켓 등록 자체는 정상 처리되는지 테스트
@pytest.mark.asyncio
async def test_ticket_registration_skips_pre_setlist_when_no_artist():
    concert_id = await _create_concert("PF_PRE_AUTO_002", artist="")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.post(
            "/api/v1/tickets", json={"concert_id": concert_id}, headers=headers
        )
    assert res.status_code == 201

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        pre_res = await ac.get(f"/api/v1/concerts/{concert_id}/setlist/pre", headers=headers)

    assert pre_res.status_code == 404


# Setlist.fm에 그 아티스트 데이터가 없어도(404) 티켓 등록은 실패하지 않고
# 조용히 예상 셋리스트만 안 만들어지는지 테스트
@pytest.mark.asyncio
async def test_ticket_registration_succeeds_when_setlistfm_has_no_data():
    concert_id = await _create_concert("PF_PRE_AUTO_003")
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    with _setlistfm_artist_mock(status_code=404):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                "/api/v1/tickets", json={"concert_id": concert_id}, headers=headers
            )
    assert res.status_code == 201

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        pre_res = await ac.get(f"/api/v1/concerts/{concert_id}/setlist/pre", headers=headers)

    assert pre_res.status_code == 404


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


# show_predicted_setlist는 더 이상 조회/생성을 막는 스위치가 아니라(프론트가
# 롱탭/홀드로 블러를 잠깐 풀어 보여주는 기능을 만들 수 있도록, 꺼져 있어도
# 데이터는 그대로 내려줘야 함) 아래 두 테스트는 "꺼도 안 막힌다"로 뒤집음.

# 설정을 꺼도 조회가 막히지 않는지 테스트
@pytest.mark.asyncio
async def test_get_pre_setlist_not_forbidden_when_setting_off():
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

    assert res.status_code == 200
    assert res.json()["songs"]


# 설정을 꺼도 생성이 막히지 않는지 테스트
@pytest.mark.asyncio
async def test_generate_pre_setlist_not_forbidden_when_setting_off():
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

    assert res.status_code == 201
