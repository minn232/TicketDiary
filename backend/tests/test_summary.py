import uuid
from datetime import date, timedelta, datetime, timezone
from unittest.mock import AsyncMock, patch

import pytest
from httpx import AsyncClient, ASGITransport

from app.core.database import AsyncSessionLocal
from app.main import app
from app.models.artist_genre import ArtistGenre
from app.models.concert import Concert
from app.models.lineup import ConcertLineup
from app.models.setlist import RealSetlist
from app.services.summary import _is_seated, _is_standing, _percent_split, _period_start
from conftest import _get_token, kopis_mock


# 아티스트 장르 캐시 직접 삽입 (Last.fm 배치/즉시 캐싱이 이미 채워둔 상태를 시뮬레이션)
async def _insert_artist_genre(artist_name: str, genres: list[str] | None) -> None:
    async with AsyncSessionLocal() as db:
        db.add(ArtistGenre(artist_name=artist_name, genres=genres))
        await db.commit()


# 헬퍼

# KOPIS 날짜 형식으로 변환 (오늘 기준 days_ago 전)
def _date_str(days_ago: int) -> str:
    return (date.today() - timedelta(days=days_ago)).strftime("%Y.%m.%d")


# KOPIS 가짜 XML 생성
def _make_kopis_xml(
    kopis_id: str,
    start: str,
    genre: str = "대중음악",
    artists: str = "테스트아티스트",
    end: str | None = None,
) -> bytes:
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f"<dbs><db>"
        f"<mt20id>{kopis_id}</mt20id>"
        f"<prfnm>{kopis_id} 공연</prfnm>"
        f"<prfpdfrom>{start}</prfpdfrom>"
        f"<prfpdto>{end or start}</prfpdto>"
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
    genre: str = "대중음악",
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
    assert _is_standing("スタンディング") is True
    assert _is_standing("스탠딩PGA석") is True
    assert _is_standing("VIP(STANDING)석") is True


# 일반 좌석은 스탠딩으로 판별하지 않는 테스트
def test_is_standing_not_detected():
    assert _is_standing("R석") is False
    assert _is_standing("VIP석") is False
    assert _is_standing("S석 3열 15번") is False
    assert _is_standing("Garden 2F") is False
    assert _is_standing("Gallery") is False
    assert _is_standing("Standard") is False
    assert _is_standing("VIP(SEATED)석") is False
    assert _is_standing("플로어석") is False
    assert _is_standing("Floor 좌석") is False


# None / 빈 문자열 입력 시 False 반환 테스트
def test_is_standing_none_returns_false():
    assert _is_standing(None) is False
    assert _is_standing("") is False


# 퍼센트 분배: 개수가 다르면 합 100, 같은 개수는 같은 퍼센트(남는 몫이 묶음에 안 맞으면 99까지 허용)
def test_percent_split_equal_counts_get_equal_percent():
    assert _percent_split([1, 1, 1]) == [33, 33, 33]
    assert _percent_split([1, 1, 2]) == [25, 25, 50]
    assert _percent_split([2, 2, 1]) == [40, 40, 20]
    assert _percent_split([2, 1]) == [67, 33]
    assert _percent_split([3, 0]) == [100, 0]
    assert _percent_split([1, 1]) == [50, 50]
    assert _percent_split([0, 0]) is None
    for counts in ([5, 7], [1, 2, 4], [13, 29]):
        assert sum(_percent_split(counts)) == 100  # 모두 다른 개수면 항상 합 100
    for counts in ([1, 1, 1], [3, 3, 3, 1], [2, 2, 2, 2, 2, 2, 2]):
        percents = _percent_split(counts)
        assert 100 - len(counts) < sum(percents) <= 100
        assert all(p1 == p2 for (c1, p1) in zip(counts, percents) for (c2, p2) in zip(counts, percents) if c1 == c2)


# _period_start 단위 테스트

# 이번 달을 포함한 최근 N개월의 1일(한국 기준 현재 달) 반환 테스트
def _months_back(months: int) -> datetime:
    now = datetime.now(timezone(timedelta(hours=9)))
    index = now.year * 12 + now.month - 1 - months
    return datetime(index // 12, index % 12 + 1, 1, tzinfo=timezone.utc)


def test_period_start_6m():
    assert _period_start("6m") == _months_back(5)


def test_period_start_1y():
    assert _period_start("1y") == _months_back(11)


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


# 공연 수·소비 금액·아티스트 중복 제거·첫콘/막콘 집계 테스트
@pytest.mark.asyncio
async def test_summary_basic_stats():
    concert_id1 = await _create_concert("PF_SUM_BASIC_001", artists="아티스트A")
    concert_id2 = await _create_concert("PF_SUM_BASIC_002", artists="아티스트B")
    concert_id3 = await _create_concert("PF_SUM_BASIC_003", artists="아티스트A")  # 아티스트A 중복
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
    # 관람 횟수 내림차순 - 아티스트A가 2번(중복 제거 대신 카운트로 반영)으로 1위
    assert data["artists"] == [
        {"name": "아티스트A", "count": 2},
        {"name": "아티스트B", "count": 1},
    ]
    assert data["first_day_count"] == 1
    assert data["last_day_count"] == 1


# 선호 장르: KOPIS 장르(Concert.genre)가 아니라 Last.fm 태그 캐시(ArtistGenre) 기준으로
# 집계되는지 테스트 - 아티스트A가 2번, 아티스트B가 1번 관람됐으니 아티스트A의 장르가 우세해야 함
@pytest.mark.asyncio
async def test_summary_top_genre_from_artist_genre_cache():
    artist_a = f"장르아티스트A_{uuid.uuid4().hex}"
    artist_b = f"장르아티스트B_{uuid.uuid4().hex}"
    concert_id1 = await _create_concert(f"PF_SUM_GENRE_{uuid.uuid4().hex[:6]}", artists=artist_a)
    concert_id2 = await _create_concert(f"PF_SUM_GENRE_{uuid.uuid4().hex[:6]}", artists=artist_b)
    concert_id3 = await _create_concert(f"PF_SUM_GENRE_{uuid.uuid4().hex[:6]}", artists=artist_a)
    token = await _get_token()

    await _insert_artist_genre(artist_a, ["K-pop"])
    await _insert_artist_genre(artist_b, ["록/밴드"])

    await _create_attended_ticket(concert_id1, token)
    await _create_attended_ticket(concert_id2, token)
    await _create_attended_ticket(concert_id3, token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/summary", headers={"Authorization": f"Bearer {token}"})

    assert res.status_code == 200
    assert res.json()["top_genre"] == "K-pop"


# 관람한 아티스트가 전부 장르 캐시에 없거나(genre=None 포함) 캐시 자체가 없으면 None
@pytest.mark.asyncio
async def test_summary_top_genre_none_when_no_matching_genre():
    artist_c = f"장르아티스트C_{uuid.uuid4().hex}"
    concert_id = await _create_concert(f"PF_SUM_GENRE_NONE_{uuid.uuid4().hex[:6]}", artists=artist_c)
    token = await _get_token()

    await _insert_artist_genre(artist_c, None)  # 태그는 받아왔지만 화이트리스트에 안 걸린 경우
    await _create_attended_ticket(concert_id, token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/summary", headers={"Authorization": f"Bearer {token}"})

    assert res.status_code == 200
    assert res.json()["top_genre"] is None


# 아티스트 한 명이 여러 장르에 걸리면(예: 힙합+K-pop), 그 아티스트를 본 티켓 하나가 두 장르
# 모두에게 표를 주는지 테스트 - artist_multi(힙합+K-pop) 1회 + artist_single(K-pop) 1회면
# K-pop이 2표(둘 다 기여), 힙합은 1표(artist_multi만 기여)라 K-pop이 우세해야 함
@pytest.mark.asyncio
async def test_summary_top_genre_counts_each_genre_of_multi_genre_artist():
    artist_multi = f"복합장르아티스트_{uuid.uuid4().hex}"
    artist_single = f"단일장르아티스트_{uuid.uuid4().hex}"
    concert_id1 = await _create_concert(f"PF_SUM_MULTI_{uuid.uuid4().hex[:6]}", artists=artist_multi)
    concert_id2 = await _create_concert(f"PF_SUM_MULTI_{uuid.uuid4().hex[:6]}", artists=artist_single)
    token = await _get_token()

    await _insert_artist_genre(artist_multi, ["힙합", "K-pop"])
    await _insert_artist_genre(artist_single, ["K-pop"])

    await _create_attended_ticket(concert_id1, token)
    await _create_attended_ticket(concert_id2, token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/summary", headers={"Authorization": f"Bearer {token}"})

    assert res.status_code == 200
    assert res.json()["top_genre"] == "K-pop"


# 티켓 1장은 1표 - 라인업이 큰 공연이 여러 장르 표를 몰아 가지 못함(솔로 2번 vs 다장르 페스티벌 1번)
@pytest.mark.asyncio
async def test_summary_top_genre_one_vote_per_ticket():
    solo = f"솔로발라드_{uuid.uuid4().hex}"
    fest = [f"페스티벌록{i}_{uuid.uuid4().hex}" for i in range(6)]
    solo_c1 = await _create_concert(f"PF_SUM_VOTE_{uuid.uuid4().hex[:6]}", artists=solo)
    solo_c2 = await _create_concert(f"PF_SUM_VOTE_{uuid.uuid4().hex[:6]}", artists=solo)
    fest_c = await _create_concert(f"PF_SUM_VOTE_{uuid.uuid4().hex[:6]}", artists=",".join(fest))
    token = await _get_token()

    await _insert_artist_genre(solo, ["발라드"])
    for name in fest:
        await _insert_artist_genre(name, ["록/밴드"])
    for c in (solo_c1, solo_c2, fest_c):
        await _create_attended_ticket(c, token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/summary", headers={"Authorization": f"Bearer {token}"})

    assert res.json()["top_genre"] == "발라드"
    assert res.json()["top_genres"] == ["발라드"]


# 동률이면 공동 1위 장르를 모두 내림
@pytest.mark.asyncio
async def test_summary_top_genres_returns_all_tied():
    artist_a = f"동률A_{uuid.uuid4().hex}"
    artist_b = f"동률B_{uuid.uuid4().hex}"
    c1 = await _create_concert(f"PF_SUM_TIE_{uuid.uuid4().hex[:6]}", artists=artist_a)
    c2 = await _create_concert(f"PF_SUM_TIE_{uuid.uuid4().hex[:6]}", artists=artist_b)
    token = await _get_token()

    await _insert_artist_genre(artist_a, ["발라드"])
    await _insert_artist_genre(artist_b, ["록/밴드"])
    await _create_attended_ticket(c1, token)
    await _create_attended_ticket(c2, token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/summary", headers={"Authorization": f"Bearer {token}"})

    assert sorted(res.json()["top_genres"]) == ["록/밴드", "발라드"]
    assert res.json()["top_genre"] in ("록/밴드", "발라드")


# 장르가 잡힌 티켓이 절반 미만이면 선호 장르를 단정하지 않음(3장 중 1장만 분류)
@pytest.mark.asyncio
async def test_summary_top_genre_none_when_coverage_low():
    known = f"분류됨_{uuid.uuid4().hex}"
    c1 = await _create_concert(f"PF_SUM_COV_{uuid.uuid4().hex[:6]}", artists=known)
    c2 = await _create_concert(f"PF_SUM_COV_{uuid.uuid4().hex[:6]}", artists=f"미분류1_{uuid.uuid4().hex}")
    c3 = await _create_concert(f"PF_SUM_COV_{uuid.uuid4().hex[:6]}", artists=f"미분류2_{uuid.uuid4().hex}")
    token = await _get_token()

    await _insert_artist_genre(known, ["발라드"])
    for c in (c1, c2, c3):
        await _create_attended_ticket(c, token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/summary", headers={"Authorization": f"Bearer {token}"})

    assert res.json()["top_genre"] is None
    assert res.json()["top_genres"] == []


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
    assert (data["standing_percent"], data["seated_percent"]) == (67, 33)


# 입장권 종류/테스트 값처럼 좌석이 아닌 구분은 스탠딩/좌석 비율 계산에서 빠짐
@pytest.mark.asyncio
async def test_summary_seat_ratio_ignores_unclear_seat_types():
    token = await _get_token()
    seat_types = ["스탠딩석", "지정석", "R석", "1일권", "테스트"]
    for i, seat_type in enumerate(seat_types):
        concert_id = await _create_concert(f"PF_SUM_SEATX_{i}_{uuid.uuid4().hex[:6]}")
        await _create_attended_ticket(concert_id, token, seat_type=seat_type)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        data = (await ac.get("/api/v1/summary", headers={"Authorization": f"Bearer {token}"})).json()
    assert (data["standing_count"], data["seated_count"]) == (1, 2)
    assert (data["standing_percent"], data["seated_percent"]) == (33, 67)


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


# 여러 날 공연(3일 전~2일 전 이틀) 셋리 두 개 저장, 관람일 지정 여부별로 요약
async def _multi_day_song_count(kopis_id: str, attended_days_ago: int | None) -> int:
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}
    xml = _make_kopis_xml(kopis_id, _date_str(3), end=_date_str(2))
    with kopis_mock(xml):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            concert_res = await ac.get(f"/api/v1/concerts/{kopis_id}", headers=headers)
    concert_id = uuid.UUID(concert_res.json()["id"])

    async with AsyncSessionLocal() as db:
        db.add(RealSetlist(
            concert_id=concert_id, performance_date=date.today() - timedelta(days=3),
            songs=[{"name": f"Day1 {i}"} for i in range(5)],
        ))
        db.add(RealSetlist(
            concert_id=concert_id, performance_date=date.today() - timedelta(days=2),
            songs=[{"name": f"Day2 {i}"} for i in range(3)],
        ))
        await db.commit()

    body: dict = {"concert_id": str(concert_id)}
    if attended_days_ago is not None:
        body["attended_date"] = (date.today() - timedelta(days=attended_days_ago)).isoformat()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        assert (await ac.post("/api/v1/tickets", json=body, headers=headers)).status_code == 201
        res = await ac.get("/api/v1/summary", headers=headers)
    return res.json()["song_count"]


# 여러 날 공연은 관람한 날 셋리 곡만 셈(안 간 날 셋리까지 합산하던 버그 회귀 방지)
@pytest.mark.asyncio
async def test_summary_song_count_multi_day_uses_attended_date_only():
    assert await _multi_day_song_count("PF_SUM_SONG_MULTI_001", attended_days_ago=2) == 3


# 관람일 모르는 여러 날 공연은 어느 날인지 추측하지 않고 곡 수에서 뺌
@pytest.mark.asyncio
async def test_summary_song_count_multi_day_without_attended_date_skipped():
    assert await _multi_day_song_count("PF_SUM_SONG_MULTI_002", attended_days_ago=None) == 0


# 여러 날 공연은 관람한 날 라인업 아티스트만 관람으로 셈(안 간 날 아티스트 제외)
@pytest.mark.asyncio
async def test_summary_artists_only_attended_day_lineup():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}
    xml = _make_kopis_xml("PF_SUM_LINEUP_001", _date_str(3), end=_date_str(2))
    with kopis_mock(xml):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            concert_res = await ac.get("/api/v1/concerts/PF_SUM_LINEUP_001", headers=headers)
    concert_id = uuid.UUID(concert_res.json()["id"])

    async with AsyncSessionLocal() as db:
        db.add(ConcertLineup(concert_id=concert_id, artist="DayOneBand", performance_date=date.today() - timedelta(days=3), source="crawl"))
        db.add(ConcertLineup(concert_id=concert_id, artist="DayTwoBand", performance_date=date.today() - timedelta(days=2), source="crawl"))
        await db.commit()

    body = {"concert_id": str(concert_id), "attended_date": (date.today() - timedelta(days=2)).isoformat()}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        assert (await ac.post("/api/v1/tickets", json=body, headers=headers)).status_code == 201
        res = await ac.get("/api/v1/summary", headers=headers)
    assert [a["name"] for a in res.json()["artists"]] == ["DayTwoBand"]


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


# 첫콘/막콘 퍼센트 - 이틀짜리 공연 3개(첫날 2번, 막날 1번) + 하루짜리 공연은 제외
@pytest.mark.asyncio
async def test_summary_first_last_day_percent_two_day_concerts_only():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}
    plan = [("A", 3, 3), ("B", 3, 3), ("C", 3, 2)]  # (id, 공연 시작 며칠 전, 관람일 며칠 전); 종료는 시작+1일
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        for suffix, start_ago, attended_ago in plan:
            kid = f"PF_SUM_DAYPCT_{suffix}_{uuid.uuid4().hex[:6]}"
            xml = _make_kopis_xml(kid, _date_str(start_ago), end=_date_str(start_ago - 1))
            with kopis_mock(xml):
                concert = await ac.get(f"/api/v1/concerts/{kid}", headers=headers)
            body = {"concert_id": concert.json()["id"],
                    "attended_date": (date.today() - timedelta(days=attended_ago)).isoformat()}
            assert (await ac.post("/api/v1/tickets", json=body, headers=headers)).status_code == 201
        res = await ac.get("/api/v1/summary", headers=headers)
    data = res.json()
    assert (data["first_day_count"], data["last_day_count"]) == (2, 1)
    assert (data["first_day_percent"], data["last_day_percent"]) == (67, 33)


# 러닝타임/event_type을 직접 지정
async def _set_runtime(concert_id: str, minutes: int | None, event_type: str = "SOLO") -> None:
    async with AsyncSessionLocal() as db:
        concert = await db.get(Concert, uuid.UUID(concert_id))
        concert.runtime_minutes = minutes
        concert.event_type = event_type
        await db.commit()


# 총 관람 시간과 셋리스트 없는 공연의 곡 수 어림치(솔로 120분 -> 24곡), 실제 곡 수와는 별개
@pytest.mark.asyncio
async def test_summary_runtime_and_estimated_songs():
    solo = await _create_concert(f"PF_SUM_RT_{uuid.uuid4().hex[:6]}")
    fest = await _create_concert(f"PF_SUM_RT_{uuid.uuid4().hex[:6]}")
    unknown = await _create_concert(f"PF_SUM_RT_{uuid.uuid4().hex[:6]}")
    await _set_runtime(solo, 120)
    await _set_runtime(fest, 480, "FESTIVAL")   # 페스티벌은 제외
    await _set_runtime(unknown, None)           # 러닝타임 모름
    token = await _get_token()
    for c in (solo, fest, unknown):
        await _create_attended_ticket(c, token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/summary", headers={"Authorization": f"Bearer {token}"})

    data = res.json()
    assert data["total_runtime_minutes"] == 120
    assert data["runtime_missing_count"] == 2
    assert data["song_count_estimated"] == 24
    assert data["song_count"] == 0


# 실제 셋리스트가 있는 공연은 어림치에서 빠짐(실제 곡 수만 song_count에)
@pytest.mark.asyncio
async def test_summary_estimated_songs_skips_concert_with_setlist():
    concert_id = await _create_concert(f"PF_SUM_RT_{uuid.uuid4().hex[:6]}")
    await _set_runtime(concert_id, 120)
    async with AsyncSessionLocal() as db:
        concert = await db.get(Concert, uuid.UUID(concert_id))
        db.add(RealSetlist(concert_id=concert.id, performance_date=concert.start_date.date(),
                           songs=[{"name": f"s{i}"} for i in range(10)]))
        await db.commit()
    token = await _get_token()
    await _create_attended_ticket(concert_id, token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/summary", headers={"Authorization": f"Bearer {token}"})

    data = res.json()
    assert data["song_count"] == 10
    assert data["song_count_estimated"] == 0
    assert data["total_runtime_minutes"] == 120


# 러닝타임이 상한(300분)을 넘는 솔로 공연은 관람 시간/곡 수 어림치에서 빠지고 누락으로 셈
@pytest.mark.asyncio
async def test_summary_runtime_over_cap_excluded():
    ok = await _create_concert(f"PF_SUM_CAP_{uuid.uuid4().hex[:6]}")
    too_long = await _create_concert(f"PF_SUM_CAP_{uuid.uuid4().hex[:6]}")
    await _set_runtime(ok, 300)
    await _set_runtime(too_long, 301)
    token = await _get_token()
    for c in (ok, too_long):
        await _create_attended_ticket(c, token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        data = (await ac.get("/api/v1/summary", headers={"Authorization": f"Bearer {token}"})).json()
    assert (data["total_runtime_minutes"], data["runtime_missing_count"], data["song_count_estimated"]) == (300, 1, 60)
