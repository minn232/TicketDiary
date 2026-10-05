"""Wikidata 한글 별칭 소급 백필 - _register_wikidata_korean_alias(mbid -> Wikidata ko label을
alias로 등록) 기능이 배포되기 전에 이미 matched된 canonical_artists는 자동으로 혜택을 못
받는다(재매치 트리거가 없어서). 1회성으로 2단계에 걸쳐 직접 채워준다:

  1단계: mbid가 있는 canonical_artists 전부 순회하며 Wikidata 한글 alias 보강.
         이미 확정된 mbid를 그대로 조회하는 것뿐이라 새로운 오매칭 위험은 없음(검색 아님).
  2단계: 2026-09-02 15:00 UTC 백필 큐잉분 중 그 다음날 새벽 배치에서 unconfirmed/ambiguous로
         확정된 것들을 pending으로 리셋. 다음 정규화 배치가 처리할 때 1단계에서 채운 alias와
         맞아떨어지면 MusicBrainz 재검색 없이 바로 matched됨 - 안 맞아떨어지는 나머지는
         원래대로 search_artist()로 자연스럽게 넘어감(밑져야 본전).

사용법:
    cd backend
    python scripts/old/backfill_wikidata_korean_aliases.py --dry-run   # 미리 확인(DB 미반영)
    python scripts/old/backfill_wikidata_korean_aliases.py             # 실제 실행
    python scripts/old/backfill_wikidata_korean_aliases.py --skip-reset  # 1단계(alias 보강)만
"""
import argparse
import asyncio
import logging
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

import httpx
from sqlalchemy import select, update

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.artist_normalization import ArtistAlias, ArtistNormalizationStatus, CanonicalArtist  # noqa: E402
from app.services.artist_normalization import _register_wikidata_korean_alias  # noqa: E402

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# 백필 큐잉 시각(dry-run/실측으로 확인된 값, v3_prod_db_temp_import 메모 참고) - 이 창에서
# unconfirmed/ambiguous로 확정된 것만 리셋 대상으로 좁힘(그 이전부터 있던, 이 사안과 무관한
# unconfirmed/ambiguous는 건드리지 않음)
_BACKFILL_WINDOW_START = datetime(2026, 9, 2, 15, 0, 0, tzinfo=timezone.utc)
_BACKFILL_WINDOW_END = datetime(2026, 9, 2, 15, 1, 0, tzinfo=timezone.utc)

_COMMIT_EVERY = 25


async def _step1_backfill_aliases(dry_run: bool) -> None:
    async with AsyncSessionLocal() as db:
        canonicals = (
            (await db.execute(select(CanonicalArtist).where(CanonicalArtist.mbid.isnot(None))))
            .scalars()
            .all()
        )
        print(f"[1단계] mbid 있는 canonical_artists {len(canonicals)}건 대상")

        async with httpx.AsyncClient(timeout=10.0) as client:
            added = 0
            for i, canonical in enumerate(canonicals, start=1):
                before = (
                    await db.execute(
                        select(ArtistAlias.id).where(
                            ArtistAlias.canonical_artist_id == canonical.id, ArtistAlias.source == "wikidata"
                        )
                    )
                ).scalar_one_or_none()

                await _register_wikidata_korean_alias(db, canonical, client)

                if before is None:
                    after = (
                        await db.execute(
                            select(ArtistAlias.alias_text).where(
                                ArtistAlias.canonical_artist_id == canonical.id, ArtistAlias.source == "wikidata"
                            )
                        )
                    ).scalar_one_or_none()
                    if after is not None:
                        added += 1
                        print(f"  + {canonical.canonical_name} -> {after}")

                if i % _COMMIT_EVERY == 0:
                    print(f"  ...{i}/{len(canonicals)} 처리, 지금까지 {added}건 추가")
                    if not dry_run:
                        await db.commit()

        if dry_run:
            await db.rollback()
            print(f"[1단계] --dry-run이라 DB에는 반영되지 않음. 실제로는 {added}건 추가됐을 것")
        else:
            await db.commit()
            print(f"[1단계] 완료: {added}건 신규 alias 추가")


async def _step2_reset_stuck_rows(dry_run: bool) -> None:
    async with AsyncSessionLocal() as db:
        target_count = (
            await db.execute(
                select(ArtistNormalizationStatus.id).where(
                    ArtistNormalizationStatus.status.in_(["unconfirmed", "ambiguous"]),
                    ArtistNormalizationStatus.created_at >= _BACKFILL_WINDOW_START,
                    ArtistNormalizationStatus.created_at < _BACKFILL_WINDOW_END,
                )
            )
        ).scalars().all()
        print(f"[2단계] pending으로 리셋 대상: {len(target_count)}건")

        if not dry_run:
            await db.execute(
                update(ArtistNormalizationStatus)
                .where(
                    ArtistNormalizationStatus.status.in_(["unconfirmed", "ambiguous"]),
                    ArtistNormalizationStatus.created_at >= _BACKFILL_WINDOW_START,
                    ArtistNormalizationStatus.created_at < _BACKFILL_WINDOW_END,
                )
                .values(status="pending", attempt_count=0, last_attempted_at=None)
            )
            await db.commit()
            print("[2단계] 완료: pending으로 리셋됨 (다음 정규화 배치가 자동으로 처리)")
        else:
            print("[2단계] --dry-run이라 DB에는 반영되지 않음")


async def main(dry_run: bool, skip_reset: bool) -> None:
    await _step1_backfill_aliases(dry_run)
    if not skip_reset:
        await _step2_reset_stuck_rows(dry_run)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="DB에 반영하지 않고 결과만 출력")
    parser.add_argument("--skip-reset", action="store_true", help="1단계(alias 보강)만 하고 2단계는 건너뜀")
    args = parser.parse_args()
    asyncio.run(main(args.dry_run, args.skip_reset))
