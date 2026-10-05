"""이미 쌓여있는 진행예정 공연에 KOPIS 내한 여부(Concert.visit)를 채우는 일회성 백필.

visit 컬럼 추가 전에 저장된 공연은 상세 API를 다시 부르지 않아 NULL이라, 진행예정 공연만 상세를
다시 조회해 visit만 채운다(다른 필드는 안 건드림). 새 공연은 일별 동기화가 상세 조회 때 같이 채움.

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/old/backfill_kopis_visit.py --dry-run
    venv/bin/python3 scripts/old/backfill_kopis_visit.py --limit 5
    venv/bin/python3 scripts/old/backfill_kopis_visit.py
"""

import argparse
import asyncio
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

import httpx  # noqa: E402
from sqlalchemy import select  # noqa: E402

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.concert import Concert  # noqa: E402
from app.services.kopis import _fetch_kopis_detail_data  # noqa: E402


async def main(limit: int | None, dry_run: bool) -> None:
    async with AsyncSessionLocal() as db:
        query = (
            select(Concert.id, Concert.kopis_id)
            .where(Concert.visit.is_(None), Concert.kopis_id.isnot(None), Concert.end_date > datetime.now(timezone.utc))
            .order_by(Concert.start_date)
        )
        if limit:
            query = query.limit(limit)
        targets = (await db.execute(query)).all()
    print(f"대상 {len(targets)}건")
    if dry_run:
        return

    updated = failed = 0
    async with httpx.AsyncClient(timeout=10.0) as client:
        for concert_id, kopis_id in targets:
            try:
                data = await _fetch_kopis_detail_data(client, kopis_id)
            except Exception as e:
                failed += 1
                print(f"실패 {kopis_id}: {e}")
                continue
            if data.get("visit") is None:
                continue
            async with AsyncSessionLocal() as db:
                concert = (await db.execute(select(Concert).where(Concert.id == concert_id))).scalar_one()
                concert.visit = data["visit"]
                await db.commit()
            updated += 1
    print(f"완료: 갱신 {updated}건, 실패 {failed}건")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=None)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    asyncio.run(main(args.limit, args.dry_run))
