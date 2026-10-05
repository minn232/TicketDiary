"""MusicBrainz 정규화 대기열(pending) 소비 배치 - 정기 스케줄러(app/batch/scheduler.py, KST
02:10, pod_stop 백업 직후)가 매일 자동 실행하지만, 수동으로 즉시 돌리거나 --dry-run으로
먼저 확인해보고 싶을 때 이 스크립트를 직접 실행하면 된다.

사용법 (서버/로컬 어디서나):
    cd backend
    python scripts/musicbrainz_normalize.py                # 기본 상한(500건)까지 처리
    python scripts/musicbrainz_normalize.py --limit 20      # 소규모로 먼저 테스트
    python scripts/musicbrainz_normalize.py --dry-run       # DB 반영 없이 결과만 확인

기존 1,178건 backfill: 별도 스크립트 없음 - artist_normalization_status에 해당 아티스트들을
pending으로 미리 넣어두기만 하면(1회성 SQL/스크립트) 이 배치가 알아서 처리한다.
"""
import argparse
import asyncio
import logging
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from app.services.artist_normalization import normalize_pending_artists  # noqa: E402

logging.basicConfig(level=logging.INFO)


async def main(limit: int, dry_run: bool) -> None:
    stats = await normalize_pending_artists(limit=limit, dry_run=dry_run)
    if stats["processed"] == 0 and stats["error"] == 0:
        print("처리할 pending 건이 없습니다.")
        return
    print(
        f"처리: {stats['processed']}건 "
        f"(matched={stats['matched']}, unconfirmed={stats['unconfirmed']}, "
        f"ambiguous={stats['ambiguous']}, error={stats['error']})"
    )
    if dry_run:
        print("--dry-run이라 DB에는 반영되지 않았습니다.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--limit", type=int, default=500, help="이번에 처리할 최대 건수 (기본 500)")
    parser.add_argument("--dry-run", action="store_true", help="DB에 반영하지 않고 결과만 출력")
    args = parser.parse_args()
    asyncio.run(main(args.limit, args.dry_run))
