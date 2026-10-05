"""LLM팀이 웹훅(send_posters_for_artist_extraction)을 안 거치고 test_batch_extract.py로
pod에서 직접 돌린 CSV가 있을 때, 백엔드 DB엔 그 시도 기록이 안 남아 artist_extraction_attempted_at이
계속 NULL로 남는 문제 보정용 일회용 스크립트. CSV의 kopis_id 목록에 해당하는 공연들에
attempted_at=now/attempt_count+1을 수동으로 찍어서, 다음 export(target 조회)에서 "한 번도
시도 안 됨"으로 다시 잡히지 않게 한다(send_posters_for_artist_extraction 성공 시와 동일한 값 기록).

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/old/mark_artist_extraction_attempted.py already_sent.csv
"""

import asyncio
import csv
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from sqlalchemy import update  # noqa: E402

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.concert import Concert  # noqa: E402


async def main(csv_path: Path) -> None:
    with open(csv_path, encoding="utf-8") as f:
        kopis_ids = [row["kopis_id"] for row in csv.DictReader(f) if row.get("kopis_id")]
    kopis_ids = list(dict.fromkeys(kopis_ids))  # 순서 유지하며 중복 제거
    print(f"CSV에서 kopis_id {len(kopis_ids)}건 읽음")

    now = datetime.now(timezone.utc)
    async with AsyncSessionLocal() as db:
        result = await db.execute(
            update(Concert)
            .where(Concert.kopis_id.in_(kopis_ids))
            .values(
                artist_extraction_attempted_at=now,
                artist_extraction_attempt_count=Concert.artist_extraction_attempt_count + 1,
            )
        )
        await db.commit()

    print(f"{result.rowcount}건에 artist_extraction_attempted_at={now.isoformat()} 기록함")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("사용법: mark_artist_extraction_attempted.py <csv_path>", file=sys.stderr)
        sys.exit(1)
    asyncio.run(main(Path(sys.argv[1])))
