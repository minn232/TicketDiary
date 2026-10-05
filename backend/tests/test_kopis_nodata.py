import uuid
from datetime import datetime, timedelta, timezone

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from app.core.database import AsyncSessionLocal
from app.main import app
from app.models.concert import Concert
from app.services.concert_search import search_concerts_db
from conftest import _get_token, kopis_mock

_NODATA_XML = (
    '<?xml version="1.0" encoding="UTF-8"?><dbs><db><returncode>04</returncode>'
    "<errmsg>NODATA ERROR</errmsg></db></dbs>"
).encode("utf-8")


async def _add_concert(kopis_id: str, name: str, **fields) -> None:
    async with AsyncSessionLocal() as db:
        db.add(Concert(
            kopis_id=kopis_id, name=name, venue="테스트공연장", artist_name=[],
            start_date=datetime.now(timezone.utc) + timedelta(days=10),
            end_date=datetime.now(timezone.utc) + timedelta(days=11), **fields,
        ))
        await db.commit()


async def _missing_at(kopis_id: str):
    async with AsyncSessionLocal() as db:
        return (await db.execute(select(Concert.kopis_missing_at).where(Concert.kopis_id == kopis_id))).scalar_one()


# KOPIS가 NODATA를 주면 장르 오류와 다른 메시지로 404를 내고 공연에 사라짐 표시를 남김
@pytest.mark.asyncio
async def test_detail_nodata_marks_concert_missing():
    kopis_id = f"PF_NODATA_{uuid.uuid4().hex[:8]}"
    await _add_concert(kopis_id, "사라진 공연")
    token = await _get_token()

    with kopis_mock(_NODATA_XML):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.get(f"/api/v1/concerts/{kopis_id}", headers={"Authorization": f"Bearer {token}"})

    assert res.status_code == 404
    assert "대중음악" not in res.json()["detail"]
    assert await _missing_at(kopis_id) is not None


# 사라짐으로 표시된 공연은 찜 검색에서 숨김, 표시 없는 공연은 그대로 나옴
@pytest.mark.asyncio
async def test_search_hides_missing_concert():
    key = uuid.uuid4().hex[:10]
    await _add_concert(f"PF_VIS_{key}", f"보이는공연{key}")
    await _add_concert(f"PF_HID_{key}", f"숨은공연{key}", kopis_missing_at=datetime.now(timezone.utc))

    async with AsyncSessionLocal() as db:
        names = [c.name for c in await search_concerts_db(db, key)]
    assert names == [f"보이는공연{key}"]
