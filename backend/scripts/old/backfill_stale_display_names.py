"""_reapply_display_name 버그(app/services/artist_normalization.py, 이 세션에 수정함 -
표시명 변경 소급반영 대상을 ConcertLineup에서만 찾아서 날짜별 출연배정이 없는 콘서트 - 단독
공연 등 상당수 - 는 안 걸리던 문제) 때문에 이미 display_name이 설정된 아티스트인데도
concert.artist_name에 옛 canonical_name 그대로 남아있는 콘서트를 한 번에 정리하는 백필
스크립트. 코드 수정은 아직 배포 전이라(서버에는 옛 버전) 이 스크립트는 고쳐진 로직을 그대로
가져오지 않고 독립적으로(concerts.artist_name을 직접 훑어서) 구현한다.

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/old/backfill_stale_display_names.py --dry-run   # 대상만 확인
    venv/bin/python3 scripts/old/backfill_stale_display_names.py             # 실제 반영
"""

import argparse
import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from collections import Counter  # noqa: E402

from sqlalchemy import select  # noqa: E402

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.artist_normalization import CanonicalArtist  # noqa: E402
from app.models.concert import Concert  # noqa: E402
from app.services.artist_normalization import apply_canonical_replacement  # noqa: E402


async def main(dry_run: bool) -> None:
    async with AsyncSessionLocal() as db:
        canonicals = (
            await db.execute(
                select(CanonicalArtist).where(CanonicalArtist.display_name.is_not(None))
            )
        ).scalars().all()
        stale = [c for c in canonicals if c.display_name != c.canonical_name]
        print(f"display_name이 설정된 canonical {len(canonicals)}개 중 {len(stale)}개가 대상")

        # canonical_name이 같은 canonical이 여러 개면(동명이인, 이번 세션에 실제로 발생한
        # JAEHA 사례) 문자열만으로 어느 쪽인지 알 수 없음 - 잘못 덮어쓰는 대신 건너뛰고 admin이
        # 직접 판단하게 함
        all_names = (await db.execute(select(CanonicalArtist.canonical_name))).scalars().all()
        name_counts = Counter(all_names)
        ambiguous = [c for c in stale if name_counts[c.canonical_name] > 1]
        stale = [c for c in stale if name_counts[c.canonical_name] == 1]
        for c in ambiguous:
            print(f"  [SKIP-동명이인] '{c.canonical_name}' -> '{c.display_name}' (같은 canonical_name이 {name_counts[c.canonical_name]}개 존재, 자동판단 불가)")

        total_concerts = 0
        for canonical in stale:
            result = await db.execute(
                select(Concert.id, Concert.kopis_id, Concert.artist_name).where(
                    Concert.artist_name.contains([canonical.canonical_name])
                )
            )
            rows = result.all()
            if not rows:
                continue
            for concert_id, kopis_id, artist_name in rows:
                print(f"  [{canonical.canonical_name} -> {canonical.display_name}] {kopis_id} {artist_name}")
                total_concerts += 1
                if not dry_run:
                    await apply_canonical_replacement(
                        db, concert_id, canonical.canonical_name, canonical.display_name,
                        clear_admin_review=True,
                    )

        print(f"\n대상 콘서트 {total_concerts}건 (dry_run={dry_run})")
        if not dry_run:
            await db.commit()
            print("반영 완료")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    asyncio.run(main(args.dry_run))
