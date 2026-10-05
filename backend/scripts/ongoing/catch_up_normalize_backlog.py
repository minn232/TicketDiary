"""정규화 대기 큐(pending) 밀린 분 한 번에 처리 - 매일 밤 배치의 500건 상한
(_DEFAULT_BATCH_LIMIT)은 MusicBrainz API 자체의 제한이 아니라 우리 배치가 하룻밤에 너무
오래 걸리지 않게 자체적으로 걸어둔 상한이라, 이 스크립트는 그 상한을 무시하고 --limit(기본
99999, 사실상 무제한)으로 한 번에 밀어붙인다. MusicBrainz의 실제 제한(초당 1회)은 기존
서비스 코드(_get_with_retry의 _throttle)가 그대로 지키므로 여기서 따로 조절할 게 없다.

사용법:
    cd backend
    python scripts/catch_up_normalize_backlog.py --dry-run   # 대상 건수만 확인(API 호출/DB 반영 없음)
    python scripts/catch_up_normalize_backlog.py             # 실제 실행(밀린 만큼 전부)
    python scripts/catch_up_normalize_backlog.py --limit 1000  # 건수 제한하고 싶을 때
"""
import argparse
import asyncio
import logging
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from sqlalchemy import func, select  # noqa: E402

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.artist_normalization import ArtistNormalizationStatus  # noqa: E402
from app.services.artist_normalization import normalize_pending_artists  # noqa: E402

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


async def main(limit: int, dry_run: bool) -> None:
    async with AsyncSessionLocal() as db:
        pending_count = (
            await db.execute(
                select(func.count()).select_from(ArtistNormalizationStatus).where(
                    ArtistNormalizationStatus.status == "pending"
                )
            )
        ).scalar_one()
    print(f"대기 중인 pending: {pending_count}건 (이번 실행 상한: {limit})")

    if dry_run:
        print("--dry-run이라 여기서 종료(API 호출 없음).")
        return

    stats = await normalize_pending_artists(limit=limit)
    print(f"완료: {stats}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--limit", type=int, default=99999, help="이번 실행에서 처리할 최대 건수")
    parser.add_argument("--dry-run", action="store_true", help="대상 건수만 출력하고 API 호출은 안 함")
    args = parser.parse_args()
    asyncio.run(main(args.limit, args.dry_run))
