"""LLM_ARTIST_URL 미연결 등으로 자동 전송이 안 되고 쌓인, 아티스트 추출 대상 공연들을
CSV(kopis_id,concert_name,poster_url,venue)로 뽑아내는 일회용 스크립트. 자동 전송 없이
export만 하므로 RunPod을 안 건드림 - LLM팀이 이 CSV를 llm_server/test_batch_extract.py에
그대로 넣어서 수동으로 돌릴 수 있음.

대상 조건은 scripts/old/send_artist_extraction_now.py의 _target_query()와 동일하게
유지(같은 필터를 그대로 재사용 - 자정 배치/수동 전송/이 export 스크립트 셋이 서로 다른
조건을 갖지 않도록).

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/old/export_artist_extraction_targets_csv.py
    venv/bin/python3 scripts/old/export_artist_extraction_targets_csv.py --out targets.csv
"""

import argparse
import asyncio
import csv
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from sqlalchemy import func, select  # noqa: E402

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.concert import Concert  # noqa: E402
from app.services.crawler import artist_extraction_target_filter  # noqa: E402


def _target_query():
    return (
        select(Concert.kopis_id, Concert.name, Concert.poster_url, Concert.venue)
        .where(
            Concert.genre.contains(["대중음악"]),
            func.cardinality(Concert.artist_name) < 4,
            Concert.poster_url.isnot(None),
            artist_extraction_target_filter(datetime.now(timezone.utc)),
        )
        .order_by(Concert.start_date)
    )


async def main(out_path: Path) -> None:
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(_target_query())).all()

    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["kopis_id", "concert_name", "poster_url", "venue"])
        for kopis_id, name, poster_url, venue in rows:
            writer.writerow([kopis_id or name, name, poster_url, venue or ""])

    print(f"{len(rows)}건을 {out_path}에 저장했습니다.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="artist_extraction_targets.csv", help="출력 CSV 경로")
    args = parser.parse_args()
    asyncio.run(main(Path(args.out)))
