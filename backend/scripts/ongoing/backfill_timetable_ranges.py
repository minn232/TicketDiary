"""이미 쌓여있는 크롤링 스크린샷에 시간표 구간(Concert.timetable_ranges)을 채우는 일회성 백필.

LLM 크롤링 분석(extract_poster_info)이 timetable_ranges를 받아야 페스티벌 아티스트 시간표를
뽑도록 바뀌어서(범위가 없으면 시간표가 비어서 옴), 컬럼 추가 전에 찍힌 스크린샷들도 범위를
계산해둬야 한다. 새 스크린샷은 crawler.py 3곳(crawl_and_save/save_manual_crawl_screenshot/
_check_festival_lineup)에서 저장 시점에 바로 계산하므로 이 스크립트는 기존분만 대상.

대상: crawl_screenshot_url 있음 + timetable_ranges IS NULL(미계산 또는 이전 Vision 실패) + 진행예정.
GCP Vision 할당량이 분당 30건이라 건마다 --interval초(기본 2.5초) 쉬면서 하나씩 처리한다.
Vision 실패 건은 NULL로 남으니 재실행하면 그것만 다시 시도함.

--resend: 범위가 1개 이상 나온 공연 중 이미 LLM 콜백을 받은 건(crawl_result_received_at)을
None으로 리셋해 다음 전송 때 다시 분석되게 한다. pod dedup이 (concert_id, screenshot_url)
단위라 pod의 processed_ids.sqlite3도 같이 지워야 실제로 재분석됨.

--recompute: 대상을 NULL 대신 "구간이 1개 이상 있는 공연"으로 바꿔 규칙 변경 후 다시 계산한다
(규칙이 줄을 빼기만 하는 변경이면 [] 공연은 결과가 안 바뀌므로 다시 안 봄).

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/ongoing/backfill_timetable_ranges.py --dry-run   # 대상 건수만
    venv/bin/python3 scripts/ongoing/backfill_timetable_ranges.py --limit 5   # 몇 건만 시험
    venv/bin/python3 scripts/ongoing/backfill_timetable_ranges.py --resend
    venv/bin/python3 scripts/ongoing/backfill_timetable_ranges.py --recompute   # 규칙 변경 후 재계산
"""

import argparse
import asyncio
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

import httpx  # noqa: E402
from sqlalchemy import func, select  # noqa: E402

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.concert import Concert  # noqa: E402
from app.services.timetable_ranges import compute_timetable_ranges  # noqa: E402


async def _target_ids(limit: int | None, recompute: bool) -> list:
    now = datetime.now(timezone.utc)
    ranges_filter = (
        func.jsonb_array_length(Concert.timetable_ranges) > 0 if recompute else Concert.timetable_ranges.is_(None)
    )
    async with AsyncSessionLocal() as db:
        query = (
            select(Concert.id)
            .where(
                Concert.crawl_screenshot_url.isnot(None),
                ranges_filter,
                Concert.end_date > now,
            )
            .order_by(Concert.start_date)
        )
        if limit:
            query = query.limit(limit)
        return list((await db.execute(query)).scalars().all())


async def _backfill_one(client: httpx.AsyncClient, concert_id, resend: bool) -> str:
    async with AsyncSessionLocal() as db:
        concert = await db.get(Concert, concert_id)
        try:
            response = await client.get(concert.crawl_screenshot_url)
            response.raise_for_status()
        except Exception as e:
            return f"다운로드 실패 {concert.name}: {e}"

        ranges = await compute_timetable_ranges(response.content)
        if ranges is None:
            return f"Vision 실패(NULL 유지) {concert.name}"

        before = concert.timetable_ranges
        concert.timetable_ranges = ranges
        reset = resend and bool(ranges) and concert.crawl_result_received_at is not None
        if reset:
            concert.crawl_result_received_at = None
        await db.commit()
        changed = f" (이전 {len(before)}구간)" if before is not None and before != ranges else ""
        return f"{len(ranges)}구간{changed}{' (재분석 리셋)' if reset else ''} {concert.name} {ranges}"


async def main(dry_run: bool, limit: int | None, interval: float, resend: bool, recompute: bool) -> None:
    ids = await _target_ids(limit, recompute)
    print(f"대상 {len(ids)}건")
    if dry_run or not ids:
        return

    async with httpx.AsyncClient(timeout=30.0) as client:
        for i, concert_id in enumerate(ids, 1):
            print(f"[{i}/{len(ids)}] {await _backfill_one(client, concert_id, resend)}", flush=True)
            if i < len(ids):
                await asyncio.sleep(interval)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--limit", type=int, default=None)
    parser.add_argument("--interval", type=float, default=2.5, help="Vision 호출 간격(초), 분당 30건 할당량 대응")
    parser.add_argument("--resend", action="store_true", help="범위가 나온 공연의 LLM 콜백 수신 기록을 리셋해 재분석")
    parser.add_argument("--recompute", action="store_true", help="구간이 이미 있는 공연을 현재 규칙으로 재계산")
    args = parser.parse_args()
    asyncio.run(main(args.dry_run, args.limit, args.interval, args.resend, args.recompute))
