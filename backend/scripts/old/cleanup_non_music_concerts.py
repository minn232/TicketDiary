"""대중음악이 아닌 장르의 공연을 DB에서 정리하는 일회용 스크립트.

2026-07-28 커밋(03d4310, "fix: resolve genre filter issues")에서 KOPIS 상세조회 경로
(get_concert_detail)에 장르 필터가 빠져있던 버그가 고쳐지기 전까지, kopis_id를 직접 아는
경로(티켓 스캔 등)로 대중음악이 아닌 공연(클래식/뮤지컬/연극 등)이 새어 들어올 수 있었다.
지금은 세 upsert 경로(_fetch_and_upsert_concerts/_fetch_all_kopis_ids/get_concert_detail)
모두 필터링되므로 신규 유입은 없고, 과거에 새어 들어온 데이터만 정리하면 된다.

사전 확인(2026-08-18, 실서버): 대상 공연 중 tickets/venue_layouts/real_setlists/pre_setlists
걸린 건 0건, timetables만 5건이라 안전하게 삭제 가능. 삭제 순서: timetables -> concerts
(concerts FK에 ondelete가 없어 순서를 지켜야 함).

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/old/cleanup_non_music_concerts.py            # 대상 건수만 확인
    venv/bin/python3 scripts/old/cleanup_non_music_concerts.py --execute  # 실제로 삭제
"""

import argparse
import asyncio
import logging
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from sqlalchemy import delete, select  # noqa: E402

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.concert import Concert  # noqa: E402
from app.models.timetable import TimeTable  # noqa: E402

logging.basicConfig(level=logging.INFO)

_NOT_MUSIC = ~Concert.genre.contains(["대중음악"])


async def main(execute: bool) -> None:
    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Concert.id, Concert.name, Concert.genre).where(_NOT_MUSIC))
        rows = result.all()
        print(f"삭제 대상 공연: {len(rows)}건")
        if not rows:
            print("삭제할 대상이 없어 종료합니다.")
            return

        for row in rows[:10]:
            print(f"  - {row.name} ({row.genre})")
        if len(rows) > 10:
            print(f"  ... 외 {len(rows) - 10}건")

        if not execute:
            print("--execute 없이 실행돼서 대상 건수만 확인하고 종료합니다 (실제로 안 지움).")
            return

        concert_ids = [row.id for row in rows]
        tt_result = await db.execute(delete(TimeTable).where(TimeTable.concert_id.in_(concert_ids)))
        c_result = await db.execute(delete(Concert).where(Concert.id.in_(concert_ids)))
        await db.commit()
        print(f"삭제 완료: 타임테이블 {tt_result.rowcount}건, 공연 {c_result.rowcount}건")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--execute", action="store_true", help="지정해야 실제로 삭제함 (기본은 확인만)")
    args = parser.parse_args()
    asyncio.run(main(args.execute))
