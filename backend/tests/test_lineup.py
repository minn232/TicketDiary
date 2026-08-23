import uuid
from datetime import date

import pytest
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from app.core.database import AsyncSessionLocal
from app.main import app
from app.models.lineup import ConcertLineup
from app.services.lineup import get_lineup_artists_for_date, upsert_concert_lineup
from conftest import _get_token, kopis_mock


# 헬퍼

def _make_kopis_xml(kopis_id: str) -> bytes:
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f"<dbs><db>"
        f"<mt20id>{kopis_id}</mt20id>"
        f"<prfnm>{kopis_id} 공연</prfnm>"
        f"<prfpdfrom>2030.06.01</prfpdfrom>"
        f"<prfpdto>2030.06.02</prfpdto>"
        f"<fcltynm>테스트공연장</fcltynm>"
        f'<poster>https://example.com/poster.jpg</poster>'
        f"<genrenm>대중음악</genrenm>"
        f"<prfstate>공연예정</prfstate>"
        f"<prfcast></prfcast>"
        f"<pcseguidance>R석 110,000원</pcseguidance>"
        f"<sty>공연 소개</sty>"
        f"</db></dbs>"
    ).encode("utf-8")


async def _create_concert(kopis_id: str) -> uuid.UUID:
    token = await _get_token()
    with kopis_mock(_make_kopis_xml(kopis_id)):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                f"/api/v1/concerts/{kopis_id}",
                headers={"Authorization": f"Bearer {token}"},
            )
    assert response.status_code == 200
    return uuid.UUID(response.json()["id"])


# 새 (아티스트,날짜) row가 없으면 추가되는지 테스트
@pytest.mark.asyncio
async def test_upsert_concert_lineup_adds_new_rows():
    concert_id = await _create_concert(f"PF_LU_ADD_{uuid.uuid4().hex[:8]}")

    async with AsyncSessionLocal() as db:
        changed = await upsert_concert_lineup(
            db,
            concert_id,
            [
                {"artist": "아티스트A", "performance_date": "2030-06-01"},
                {"artist": "아티스트B", "performance_date": "2030-06-02"},
            ],
            source="crawl",
        )
    assert changed is True

    async with AsyncSessionLocal() as db:
        result = await db.execute(select(ConcertLineup).where(ConcertLineup.concert_id == concert_id))
        rows = {(r.artist, r.performance_date, r.source) for r in result.scalars().all()}
    assert rows == {
        ("아티스트A", date(2030, 6, 1), "crawl"),
        ("아티스트B", date(2030, 6, 2), "crawl"),
    }


# 같은 아티스트가 여러 날짜에 걸쳐 출연해도 (concert_id, artist, performance_date) 조합별로
# 별도 row가 쌓이는지 테스트 (아티스트당 날짜 1개라는 예전 가정을 버린 이유)
@pytest.mark.asyncio
async def test_upsert_concert_lineup_same_artist_multiple_dates():
    concert_id = await _create_concert(f"PF_LU_MULTI_{uuid.uuid4().hex[:8]}")

    async with AsyncSessionLocal() as db:
        await upsert_concert_lineup(
            db,
            concert_id,
            [
                {"artist": "헤드라이너", "performance_date": "2030-06-01"},
                {"artist": "헤드라이너", "performance_date": "2030-06-02"},
            ],
            source="crawl",
        )

    async with AsyncSessionLocal() as db:
        day1 = await get_lineup_artists_for_date(db, concert_id, date(2030, 6, 1))
        day2 = await get_lineup_artists_for_date(db, concert_id, date(2030, 6, 2))
    assert day1 == ["헤드라이너"]
    assert day2 == ["헤드라이너"]


# union-only 병합: 이미 있는 (아티스트,날짜)는 유지되고, 새 것만 추가되는지(삭제/교체 없음) 테스트
@pytest.mark.asyncio
async def test_upsert_concert_lineup_union_only_no_delete():
    concert_id = await _create_concert(f"PF_LU_UNION_{uuid.uuid4().hex[:8]}")

    async with AsyncSessionLocal() as db:
        await upsert_concert_lineup(
            db, concert_id, [{"artist": "아티스트A", "performance_date": "2030-06-01"}], source="poster"
        )
    # 두 번째 배치는 A와 겹치지 않는 새 아티스트만 보냄 - A row는 그대로 남아야 함
    async with AsyncSessionLocal() as db:
        await upsert_concert_lineup(
            db, concert_id, [{"artist": "아티스트C", "performance_date": "2030-06-02"}], source="poster"
        )

    async with AsyncSessionLocal() as db:
        result = await db.execute(select(ConcertLineup).where(ConcertLineup.concert_id == concert_id))
        artists = {r.artist for r in result.scalars().all()}
    assert artists == {"아티스트A", "아티스트C"}


# 병합 우선순위: poster로 먼저 확인된 배정이 나중에 crawl로 재확인되면 source가 승격되는지,
# 반대로 crawl이 먼저 확인된 배정은 나중에 poster가 와도 안 밀리는지 테스트
@pytest.mark.asyncio
async def test_upsert_concert_lineup_crawl_source_priority():
    concert_id = await _create_concert(f"PF_LU_PRIO_{uuid.uuid4().hex[:8]}")

    async with AsyncSessionLocal() as db:
        await upsert_concert_lineup(
            db, concert_id, [{"artist": "아티스트A", "performance_date": "2030-06-01"}], source="poster"
        )
    async with AsyncSessionLocal() as db:
        changed = await upsert_concert_lineup(
            db, concert_id, [{"artist": "아티스트A", "performance_date": "2030-06-01"}], source="crawl"
        )
    assert changed is True  # poster -> crawl 승격

    async with AsyncSessionLocal() as db:
        result = await db.execute(select(ConcertLineup).where(ConcertLineup.concert_id == concert_id))
        row = result.scalar_one()
    assert row.source == "crawl"

    # crawl로 확정된 뒤 poster가 같은 (아티스트,날짜)를 다시 보내도 안 바뀜(변경 없음 보고)
    async with AsyncSessionLocal() as db:
        changed_again = await upsert_concert_lineup(
            db, concert_id, [{"artist": "아티스트A", "performance_date": "2030-06-01"}], source="poster"
        )
    assert changed_again is False

    async with AsyncSessionLocal() as db:
        result = await db.execute(select(ConcertLineup).where(ConcertLineup.concert_id == concert_id))
        row = result.scalar_one()
    assert row.source == "crawl"


# 배정 정보가 아예 없는 (concert_id, date) 조합은 None(폴백 신호)을 반환하는지 테스트
@pytest.mark.asyncio
async def test_get_lineup_artists_for_date_returns_none_when_no_data():
    concert_id = await _create_concert(f"PF_LU_NONE_{uuid.uuid4().hex[:8]}")

    async with AsyncSessionLocal() as db:
        result = await get_lineup_artists_for_date(db, concert_id, date(2030, 6, 1))
    assert result is None
