"""canonical 아티스트의 MusicBrainz 장르/국가(mb_genres, mb_country)를 채우는 백필.

일일 배치(sync_musicbrainz_genres)가 하루 300명씩 채우므로 이 스크립트는 처음 한 번에 몰아서 채울 때만 쓴다.
MusicBrainz 호출 간격이 2초라 4,800명이면 약 2시간 40분 걸린다 - 03:00~05:10 LLM 콜백 구간(웹훅이 같은
호출 제한기를 쓰는 즉시 정규화를 띄움)을 피해 낮에 nohup으로 돌릴 것.

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/ongoing/backfill_musicbrainz_genres.py --dry-run   # 대상 건수만
    venv/bin/python3 scripts/ongoing/backfill_musicbrainz_genres.py --limit 20  # 몇 명만 시험
    nohup venv/bin/python3 scripts/ongoing/backfill_musicbrainz_genres.py --limit 5000 > /tmp/mb_genres.log 2>&1 &
"""

import argparse
import asyncio
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from sqlalchemy import func, or_, select  # noqa: E402

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.artist_normalization import CanonicalArtist  # noqa: E402
from app.services.artist_genre import _MB_GENRE_TTL, sync_musicbrainz_genres  # noqa: E402


async def main(limit: int, dry_run: bool) -> None:
    cutoff = datetime.now(timezone.utc) - _MB_GENRE_TTL
    async with AsyncSessionLocal() as db:
        total = (
            await db.execute(
                select(func.count()).where(
                    CanonicalArtist.mbid.isnot(None),
                    or_(CanonicalArtist.mb_genres_fetched_at.is_(None), CanonicalArtist.mb_genres_fetched_at < cutoff),
                )
            )
        ).scalar_one()
    print(f"조회 대상 {total}명 (이번 실행 상한 {limit}명, 예상 {min(total, limit) * 2 / 60:.0f}분)")
    if dry_run:
        return
    print(await sync_musicbrainz_genres(limit=limit))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=300)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    asyncio.run(main(args.limit, args.dry_run))
