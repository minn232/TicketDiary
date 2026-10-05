"""
자정 배치(_run_daily_kopis_sync)를 기다리지 않고 KOPIS 동기화를 즉시 1회 실행하는 일회용 스크립트.

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/run_kopis_sync_once.py
"""

import asyncio
import logging
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from sqlalchemy import func, select  # noqa: E402

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.concert import Concert  # noqa: E402
from app.services.kopis import sync_daily_concerts  # noqa: E402

logging.basicConfig(level=logging.INFO)


async def main() -> None:
    async with AsyncSessionLocal() as db:
        before = await db.scalar(select(func.count()).select_from(Concert))

    print(f"동기화 전 concerts 건수: {before}")
    print("KOPIS 동기화 시작...")

    async with AsyncSessionLocal() as db:
        await sync_daily_concerts(db)

    async with AsyncSessionLocal() as db:
        after = await db.scalar(select(func.count()).select_from(Concert))

    print(f"동기화 후 concerts 건수: {after} (신규 {after - before}건)")


if __name__ == "__main__":
    asyncio.run(main())
