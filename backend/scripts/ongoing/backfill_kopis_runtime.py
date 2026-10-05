"""이미 쌓여있는 공연에 KOPIS 러닝타임(Concert.runtime_minutes)을 채우는 백필.

runtime_minutes 컬럼 추가 전에 저장된 공연은 상세 API를 다시 부르지 않아 NULL이라, 상세를 다시
조회해 runtime_minutes만 채운다(다른 필드는 안 건드림). 지난 공연도 대상(관람 시간 결산에 필요).
KOPIS가 러닝타임을 안 주는 공연은 NULL로 남아 재실행하면 다시 시도됨. 새 공연은 일별 동기화가
상세 조회 때 같이 채움. 호출 간격이 0.35초라 공연 1,900건이면 약 11분.

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/ongoing/backfill_kopis_runtime.py --dry-run
    venv/bin/python3 scripts/ongoing/backfill_kopis_runtime.py --limit 5
    venv/bin/python3 scripts/ongoing/backfill_kopis_runtime.py
"""

import argparse
import asyncio
import sys
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
            .where(Concert.runtime_minutes.is_(None), Concert.kopis_id.isnot(None))
            .order_by(Concert.start_date.desc())
        )
        if limit:
            query = query.limit(limit)
        targets = (await db.execute(query)).all()
    print(f"대상 {len(targets)}건")
    if dry_run:
        return

    updated = no_runtime = failed = 0
    async with httpx.AsyncClient(timeout=10.0) as client:
        for i, (concert_id, kopis_id) in enumerate(targets, 1):
            try:
                data = await _fetch_kopis_detail_data(client, kopis_id)
            except Exception as e:
                failed += 1
                print(f"실패 {kopis_id}: {e}")
                continue
            if data.get("runtime_minutes") is None:
                no_runtime += 1
                continue
            async with AsyncSessionLocal() as db:
                concert = (await db.execute(select(Concert).where(Concert.id == concert_id))).scalar_one()
                concert.runtime_minutes = data["runtime_minutes"]
                await db.commit()
            updated += 1
            if i % 100 == 0:
                print(f"진행 {i}/{len(targets)}")
    print(f"완료: 갱신 {updated}건, 러닝타임 없음 {no_runtime}건, 실패 {failed}건")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=None)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    asyncio.run(main(args.limit, args.dry_run))
