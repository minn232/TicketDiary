import uuid
from datetime import date, timedelta

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from app.core.database import AsyncSessionLocal
from app.main import app
from app.models.artist_normalization import CanonicalArtist
from app.models.concert import Concert
from app.models.setlist import PreSetlist, RealSetlist
from app.models.ticket import Ticket
from app.services.summary_extras import percent_split
from conftest import _get_token
from test_summary import _create_attended_ticket, _create_concert


async def _get_summary(token: str, period: str = "all") -> dict:
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get(f"/api/v1/summary?period={period}", headers={"Authorization": f"Bearer {token}"})
    assert res.status_code == 200
    return res.json()


async def _update_ticket(ticket_id: str, **fields) -> None:
    async with AsyncSessionLocal() as db:
        ticket = await db.get(Ticket, uuid.UUID(ticket_id))
        for key, value in fields.items():
            setattr(ticket, key, value)
        await db.commit()


def _uid() -> str:
    return uuid.uuid4().hex[:8]


def test_percent_split_helper_shared():
    assert percent_split([1, 1]) == [50, 50]


# 티켓 필드 통계: 공연장/요일/최고 지출/평균/예매처/사진/일기/최다 월
@pytest.mark.asyncio
async def test_summary_ticket_field_extras():
    token = await _get_token()
    c1 = await _create_concert(f"PF_EX_{_uid()}", days_ago=10)
    c2 = await _create_concert(f"PF_EX_{_uid()}", days_ago=11)
    c3 = await _create_concert(f"PF_EX_{_uid()}", days_ago=400)
    t1 = await _create_attended_ticket(c1, token, price=100000)
    t2 = await _create_attended_ticket(c2, token, price=50000)
    t3 = await _create_attended_ticket(c3, token)  # 가격 없음
    await _update_ticket(t1, ticketing_site="INTERPARK", concert_photo_urls=["a", "b"], diary="일기")
    await _update_ticket(t2, ticketing_site="NOL ticket", concert_photo_urls=["c"], diary="  ")
    await _update_ticket(t3, ticketing_site="YES24")

    data = await _get_summary(token)
    assert data["top_venues"] == [{"name": "테스트공연장", "count": 3}]
    assert sum(data["weekday_counts"]) == 3 and len(data["weekday_counts"]) == 7
    assert data["max_spend"]["price"] == 100000
    assert data["avg_ticket_price"] == 75000
    sites = {s["name"]: s for s in data["ticketing_sites"]}
    assert sites["INTERPARK"]["count"] == 2 and sites["YES24"]["count"] == 1  # NOL 합침
    assert sum(s["percent"] for s in data["ticketing_sites"]) == 100
    assert data["ticketing_site_unknown_count"] == 0
    assert data["photo_count"] == 3
    assert data["diary_count"] == 1  # 공백뿐인 일기는 제외
    assert data["busiest_month"]["count"] >= 2


# 가장 많이 쓴 아티스트는 아티스트 1명인 공연만, 첫 관람 아티스트는 선택 기간 이전 기록 기준
@pytest.mark.asyncio
async def test_summary_artist_extras():
    token = await _get_token()
    old_artist, new_artist, fest_a, fest_b = (f"{n}_{_uid()}" for n in ("옛날", "새", "페A", "페B"))
    old = await _create_concert(f"PF_EXA_{_uid()}", days_ago=300, artists=old_artist)
    recent_old = await _create_concert(f"PF_EXA_{_uid()}", days_ago=20, artists=old_artist)
    recent_new = await _create_concert(f"PF_EXA_{_uid()}", days_ago=10, artists=new_artist)
    fest = await _create_concert(f"PF_EXA_{_uid()}", days_ago=5, artists=f"{fest_a},{fest_b}")
    for cid, price in ((old, 10000), (recent_old, 20000), (recent_new, 30000), (fest, 999999)):
        await _create_attended_ticket(cid, token, price=price)

    data = await _get_summary(token, "6m")
    assert data["top_spend_artist"] == {"name": new_artist, "amount": 30000}  # 페스티벌 가격 제외
    assert new_artist in data["new_artists"] and fest_a in data["new_artists"]
    assert old_artist not in data["new_artists"]  # 6개월 전에 이미 봄

    assert old_artist in (await _get_summary(token, "all"))["new_artists"]  # 전체 기간이면 전부 신규


# 내한 vs 국내: MB 국가 우선, 국가 없으면 KOPIS visit, 둘 다 없으면 미분류
@pytest.mark.asyncio
async def test_summary_origin_extras():
    token = await _get_token()
    kr, jp, none = (f"{n}_{_uid()}" for n in ("국내", "일본", "국가없음"))
    async with AsyncSessionLocal() as db:
        db.add(CanonicalArtist(canonical_name=kr, mb_country="KR"))
        db.add(CanonicalArtist(canonical_name=jp, mb_country="JP"))
        await db.commit()
    ids = [await _create_concert(f"PF_EXO_{_uid()}", artists=a) for a in (kr, jp, jp, none)]
    for cid in ids:
        await _create_attended_ticket(cid, token)

    data = await _get_summary(token)
    assert (data["origin_domestic_percent"], data["origin_foreign_percent"]) == (33, 67)
    assert data["origin_unknown_count"] == 1

    async with AsyncSessionLocal() as db:  # visit=True면 국가 모르는 공연도 해외로 분류
        concert = await db.get(Concert, uuid.UUID(ids[3]))
        concert.visit = True
        await db.commit()
    data = await _get_summary(token)
    assert data["origin_unknown_count"] == 0 and data["origin_foreign_percent"] == 75


# 가장 많이 들은 곡(아티스트+곡명 정규화, 2번 이상)과 가장 희귀한 곡(예상 확률 최저, 예상 밖은 0)
@pytest.mark.asyncio
async def test_summary_song_extras():
    token = await _get_token()
    artist = f"곡아티스트_{_uid()}"
    c1 = await _create_concert(f"PF_EXS_{_uid()}", days_ago=20, artists=artist)
    c2 = await _create_concert(f"PF_EXS_{_uid()}", days_ago=10, artists=artist)
    async with AsyncSessionLocal() as db:
        for cid, days, songs in ((c1, 20, ["Hit Song", "Deep Cut"]), (c2, 10, ["hit  song", "Surprise"])):
            concert = await db.get(Concert, uuid.UUID(cid))
            db.add(RealSetlist(concert_id=concert.id, performance_date=concert.start_date.date(),
                               songs=[{"name": n, "encore": False} for n in songs]))
        await db.commit()
    for cid in (c1, c2):
        await _create_attended_ticket(cid, token)
    # 티켓 등록이 예상 셋리 빈 자리표시 행을 만들 수 있어, 그 뒤에 c1 예상 셋리를 채움
    async with AsyncSessionLocal() as db:
        pre = (await db.execute(select(PreSetlist).where(PreSetlist.concert_id == uuid.UUID(c1)))).scalar_one_or_none()
        songs = [{"name": "Hit Song", "probability": 0.9}, {"name": "Deep Cut", "probability": 0.2}]
        if pre is None:
            db.add(PreSetlist(concert_id=uuid.UUID(c1), songs=songs))
        else:
            pre.songs = songs
        await db.commit()

    data = await _get_summary(token)
    assert data["most_heard_song"]["count"] == 2 and data["most_heard_song"]["name"] == "Hit Song"
    # c2에는 예상 셋리가 없어 판단 제외, c1에서는 확률 0.2의 Deep Cut이 가장 희귀
    assert data["rarest_song"]["name"] == "Deep Cut" and data["rarest_song"]["probability"] == 0.2


# 데이터가 없으면 값이 비고 응답 형식은 유지
@pytest.mark.asyncio
async def test_summary_extras_empty():
    data = await _get_summary(await _get_token())
    assert data["top_venues"] == [] and data["weekday_counts"] == [0] * 7
    assert data["max_spend"] is None and data["most_heard_song"] is None and data["rarest_song"] is None


# 월별 관람/지출: 빈 달은 0으로 채우고 오래된 달부터 이번 달까지
@pytest.mark.asyncio
async def test_summary_monthly_stats():
    token = await _get_token()
    days = (3, 70, 71)
    ids = [await _create_concert(f"PF_EXM_{_uid()}", days_ago=d) for d in days]
    for cid, price in zip(ids, (10000, 20000, None)):
        await _create_attended_ticket(cid, token, price=price)

    months = (await _get_summary(token))["monthly_stats"]
    expected_count: dict[str, int] = {}
    expected_spent: dict[str, int] = {}
    for d, price in zip(days, (10000, 20000, 0)):
        key = (date.today() - timedelta(days=d)).strftime("%Y-%m")
        expected_count[key] = expected_count.get(key, 0) + 1
        expected_spent[key] = expected_spent.get(key, 0) + price

    keys = [m["month"] for m in months]
    assert keys == sorted(keys) and keys[-1] == date.today().strftime("%Y-%m")
    assert len(set(keys)) == len(keys) and len(keys) >= 3  # 사이 달도 빠짐없이
    for m in months:
        assert m["concert_count"] == expected_count.get(m["month"], 0)
        assert m["spent"] == expected_spent.get(m["month"], 0)


# 기록이 없으면 빈 배열
@pytest.mark.asyncio
async def test_summary_monthly_stats_empty():
    assert (await _get_summary(await _get_token()))["monthly_stats"] == []
