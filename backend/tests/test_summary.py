from datetime import date, timedelta, datetime, timezone
from unittest.mock import AsyncMock, patch

import pytest
from httpx import AsyncClient, ASGITransport

from app.main import app
from app.services.summary import _is_standing, _period_start
from conftest import _get_token, kopis_mock


# 헬퍼

# KOPIS 날짜 형식으로 변환 (오늘 기준 days_ago 전)
def _date_str(days_ago: int) -> str:
    return (date.today() - timedelta(days=days_ago)).strftime("%Y.%m.%d")


# KOPIS 가짜 XML 생성
def _make_kopis_xml(
    kopis_id: str,
    start: str,
    genre: str = "팝",
    artists: str = "테스트아티스트",
) -> bytes:
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f"<dbs><db>"
        f"<mt20id>{kopis_id}</mt20id>"
        f"<prfnm>{kopis_id} 공연</prfnm>"
        f"<prfpdfrom>{start}</prfpdfrom>"
        f"<prfpdto>{start}</prfpdto>"
        f"<fcltynm>테스트공연장</fcltynm>"
        f"<genrenm>{genre}</genrenm>"
        f"<prfcast>{artists}</prfcast>"
        f"<pcseguidance></pcseguidance>"
        f"<sty></sty>"
        f"</db></dbs>"
    ).encode("utf-8")


# 공연 생성 (KOPIS mock 사용)
async def _create_concert(
    kopis_id: str,
    days_ago: int = 30,
    genre: str = "팝",
    artists: str = "테스트아티스트",
) -> str:
    token = await _get_token()
    xml = _make_kopis_xml(kopis_id, _date_str(days_ago), genre, artists)
    with kopis_mock(xml):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.get(
                f"/api/v1/concerts/{kopis_id}",
                headers={"Authorization": f"Bearer {token}"},
            )
    assert res.status_code == 200
    return res.json()["id"]


# AFTER_CONCERT 티켓 생성 (등록 후 상태 변경까지)
async def _create_attended_ticket(
    concert_id: str,
    token: str,
    *,
    seat_type: str | None = None,
    price: int | None = None,
    is_first_day: bool | None = None,
    is_last_day: bool | None = None,
) -> str:
    headers = {"Authorization": f"Bearer {token}"}

    create_body: dict = {"concert_id": concert_id}
    if seat_type is not None:
        create_body["seat_type"] = seat_type
    if price is not None:
        create_body["price"] = price

    update_body: dict = {}
    if is_first_day is not None:
        update_body["is_first_day"] = is_first_day
    if is_last_day is not None:
        update_body["is_last_day"] = is_last_day

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.post("/api/v1/tickets", json=create_body, headers=headers)
        assert res.status_code == 201
        ticket_id = res.json()["id"]
        await ac.patch(f"/api/v1/tickets/{ticket_id}", json=update_body, headers=headers)

    return ticket_id


# _is_standing 단위 테스트

# 스탠딩 키워드 감지 테스트
def test_is_standing_detected():
    assert _is_standing("스탠딩") is True
    assert _is_standing("STANDING A구역") is True
    assert _is_standing("GA") is True
    assert _is_standing("floor") is True
    assert _is_standing("입석") is True


# 일반 좌석은 스탠딩으로 판별하지 않는 테스트
def test_is_standing_not_detected():
    assert _is_standing("R석") is False
    assert _is_standing("VIP석") is False
    assert _is_standing("S석 3열 15번") is False


# None / 빈 문자열 입력 시 False 반환 테스트
def test_is_standing_none_returns_false():
    assert _is_standing(None) is False
    assert _is_standing("") is False


# _period_start 단위 테스트

# 6m -> 183일 전 datetime 반환 테스트
def test_period_start_6m():
    result = _period_start("6m")
    expected = datetime.now(timezone.utc) - timedelta(days=183)
    assert abs((result - expected).total_seconds()) < 5


# 1y -> 365일 전 datetime 반환 테스트
def test_period_start_1y():
    result = _period_start("1y")
    expected = datetime.now(timezone.utc) - timedelta(days=365)
    assert abs((result - expected).total_seconds()) < 5


# all -> None 반환 테스트
def test_period_start_all_returns_none():
    assert _period_start("all") is None


# /summary 통합 테스트

# 티켓이 없으면 모든 값이 0 또는 빈값 테스트
@pytest.mark.asyncio
async def test_summary_empty():
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/summary", headers={"Authorization": f"Bearer {token}"})

    assert res.status_code == 200
    data = res.json()
    assert data["concert_count"] == 0
    assert data["song_count"] == 0
    assert data["total_spent"] == 0
    assert data["top_genre"] is None
    assert data["artists"] == []
    assert data["standing_count"] == 0
    assert data["seated_count"] == 0
    assert data["first_day_count"] == 0
    assert data["last_day_count"] == 0


# before_concert 티켓은 결산에 포함되지 않는 테스트 (미래 공연 → 자동 BEFORE_CONCERT)
@pytest.mark.asyncio
async def test_summary_only_after_concert_counts():
    # 미래 공연 2개 (자동 BEFORE_CONCERT 상태)
    concert_id1 = await _create_concert("PF_SUM_FUTURE_001", days_ago=-30)
    concert_id2 = await _create_concert("PF_SUM_FUTURE_002", days_ago=-60)
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.post("/api/v1/tickets", json={"concert_id": concert_id1}, headers=headers)
        await ac.post("/api/v1/tickets", json={"concert_id": concert_id2}, headers=headers)
        res = await ac.get("/api/v1/summary", headers=headers)

    assert res.status_code == 200
    assert res.json()["concert_count"] == 0


# 공연 수·소비 금액·장르·아티스트 중복 제거·첫콘/막콘 집계 테스트
@pytest.mark.asyncio
async def test_summary_basic_stats():
    concert_id1 = await _create_concert("PF_SUM_BASIC_001", genre="팝", artists="아티스트A")
    concert_id2 = await _create_concert("PF_SUM_BASIC_002", genre="팝", artists="아티스트B")
    concert_id3 = await _create_concert("PF_SUM_BASIC_003", genre="록", artists="아티스트A")  # 아티스트A 중복
    token = await _get_token()

    await _create_attended_ticket(concert_id1, token, price=110000, is_first_day=True)
    await _create_attended_ticket(concert_id2, token, price=90000, is_last_day=True)
    await _create_attended_ticket(concert_id3, token, price=80000)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/summary", headers={"Authorization": f"Bearer {token}"})

    assert res.status_code == 200
    data = res.json()
    assert data["concert_count"] == 3
    assert data["total_spent"] == 280000
    assert data["top_genre"] == "팝"                               # 팝 2회 vs 록 1회
    assert set(data["artists"]) == {"아티스트A", "아티스트B"}      # 아티스트A 중복 제거
    assert data["first_day_count"] == 1
    assert data["last_day_count"] == 1


# 스탠딩 / 좌석 / 미집계 카운트 테스트
@pytest.mark.asyncio
async def test_summary_standing_and_seated():
    concert_id1 = await _create_concert("PF_SUM_STAND_001")
    concert_id2 = await _create_concert("PF_SUM_STAND_002")
    concert_id3 = await _create_concert("PF_SUM_STAND_003")
    concert_id4 = await _create_concert("PF_SUM_STAND_004")
    token = await _get_token()

    await _create_attended_ticket(concert_id1, token, seat_type="스탠딩")
    await _create_attended_ticket(concert_id2, token, seat_type="GA")
    await _create_attended_ticket(concert_id3, token, seat_type="R석 3열")
    await _create_attended_ticket(concert_id4, token)              # seat_type 없음 -> 미집계

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/summary", headers={"Authorization": f"Bearer {token}"})

    assert res.status_code == 200
    data = res.json()
    assert data["standing_count"] == 2
    assert data["seated_count"] == 1


# 실제 셋리스트 등록 후 곡 수 합산 테스트
@pytest.mark.asyncio
async def test_summary_song_count():
    concert_id = await _create_concert("PF_SUM_SONG_001", artists="아티스트A")
    token = await _get_token()
    await _create_attended_ticket(concert_id, token)
    headers = {"Authorization": f"Bearer {token}"}

    fake_songs = [
        {"name": "Song 1", "encore": False},
        {"name": "Song 2", "encore": False},
        {"name": "Song 3", "encore": True},
    ]
    with (
        patch("app.services.setlist.get_setlist_by_id", new=AsyncMock(return_value={})),
        patch("app.services.setlist.extract_songs", return_value=fake_songs),
    ):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            setlist_res = await ac.post(
                f"/api/v1/concerts/{concert_id}/setlist",
                json={"setlistfm_id": "fake-id"},
                headers=headers,
            )
            assert setlist_res.status_code == 201

            res = await ac.get("/api/v1/summary", headers=headers)

    assert res.status_code == 200
    assert res.json()["song_count"] == 3


# 6m 필터: 183일 초과 공연 제외 테스트
@pytest.mark.asyncio
async def test_summary_period_6m():
    recent_id = await _create_concert("PF_SUM_6M_RECENT", days_ago=30)    # 포함
    old_id    = await _create_concert("PF_SUM_6M_OLD",    days_ago=240)   # 제외
    token = await _get_token()

    await _create_attended_ticket(recent_id, token, price=110000)
    await _create_attended_ticket(old_id,    token, price=90000)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/summary?period=6m", headers={"Authorization": f"Bearer {token}"})

    assert res.status_code == 200
    data = res.json()
    assert data["concert_count"] == 1
    assert data["total_spent"] == 110000


# 1y 필터: 365일 이내 포함, 초과 제외 테스트
@pytest.mark.asyncio
async def test_summary_period_1y():
    recent_id = await _create_concert("PF_SUM_1Y_RECENT", days_ago=30)    # 포함
    medium_id = await _create_concert("PF_SUM_1Y_MEDIUM", days_ago=240)   # 포함
    old_id    = await _create_concert("PF_SUM_1Y_OLD",    days_ago=730)   # 제외
    token = await _get_token()

    await _create_attended_ticket(recent_id, token, price=110000)
    await _create_attended_ticket(medium_id, token, price=90000)
    await _create_attended_ticket(old_id,    token, price=80000)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/summary?period=1y", headers={"Authorization": f"Bearer {token}"})

    assert res.status_code == 200
    data = res.json()
    assert data["concert_count"] == 2
    assert data["total_spent"] == 200000


# all 필터: 오래된 공연 포함 전체 집계 테스트
@pytest.mark.asyncio
async def test_summary_period_all():
    recent_id = await _create_concert("PF_SUM_ALL_RECENT", days_ago=30)
    old_id    = await _create_concert("PF_SUM_ALL_OLD",    days_ago=730)
    token = await _get_token()

    await _create_attended_ticket(recent_id, token, price=110000)
    await _create_attended_ticket(old_id,    token, price=80000)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/summary?period=all", headers={"Authorization": f"Bearer {token}"})

    assert res.status_code == 200
    data = res.json()
    assert data["concert_count"] == 2
    assert data["total_spent"] == 190000


# 유저 간 결산 데이터 격리 테스트
@pytest.mark.asyncio
async def test_summary_user_isolation():
    concert_id = await _create_concert("PF_SUM_ISO_001")
    token_a = await _get_token()
    token_b = await _get_token()

    await _create_attended_ticket(concert_id, token_a, price=110000)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res_b = await ac.get("/api/v1/summary", headers={"Authorization": f"Bearer {token_b}"})

    assert res_b.status_code == 200
    assert res_b.json()["concert_count"] == 0
    assert res_b.json()["total_spent"] == 0


# 미인증 요청 401 반환 테스트
@pytest.mark.asyncio
async def test_summary_unauthorized():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/summary")

    assert res.status_code == 401
