"""사진 없는 아티스트(canonical)의 사진을 다시 찾는 백필 스크립트.

사진은 정규화로 매칭될 때 한 번만 찾아서(register_artist_image), 사진 출처(벅스/YouTube 대표
이미지)를 추가하기 전에 매칭된 아티스트는 저절로 안 채워짐. mbid가 있고 사진이 없는 canonical을
다시 조회함.

- 기본은 진행 예정 공연에 나오는 아티스트만(화면에 보이는 것 위주), --all이면 전체
- MusicBrainz 초당 1요청 제한 때문에 한 명당 몇 초 걸림(링크 조회 최대 3번)
- 이미 사진이 있으면 건드리지 않음

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/ongoing/backfill_artist_images.py --dry-run     # 대상만 확인
    venv/bin/python3 scripts/ongoing/backfill_artist_images.py --limit 10    # 10명만 먼저
    venv/bin/python3 scripts/ongoing/backfill_artist_images.py
    venv/bin/python3 scripts/ongoing/backfill_artist_images.py --all        # 공연 없는 아티스트 포함
"""

import argparse
import asyncio
import sys
from datetime import datetime, timezone
from pathlib import Path

_BACKEND_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_BACKEND_ROOT))

import httpx  # noqa: E402
from sqlalchemy import func, or_, select  # noqa: E402

from app.core.database import AsyncSessionLocal, engine  # noqa: E402
from app.models.artist_normalization import ArtistAlias, CanonicalArtist  # noqa: E402
from app.models.concert import Concert  # noqa: E402
from app.services.artist_normalization import register_artist_image  # noqa: E402

engine.echo = False  # 서버 설정이 SQL을 전부 찍어서 진행 로그가 묻힘


# 사진 없고 mbid 있는 canonical. include_all이 아니면 진행 예정 공연의 아티스트명(canonical_name
# 또는 별칭)과 일치하는 것만
async def _targets(include_all: bool) -> list[tuple]:
    async with AsyncSessionLocal() as db:
        query = select(CanonicalArtist.id, CanonicalArtist.canonical_name).where(
            CanonicalArtist.mbid.is_not(None), CanonicalArtist.profile_image_url.is_(None)
        )
        if not include_all:
            upcoming = (
                select(func.lower(func.unnest(Concert.artist_name)))
                .where(Concert.end_date >= datetime.now(timezone.utc))
                .scalar_subquery()
            )
            aliased = select(ArtistAlias.canonical_artist_id).where(func.lower(ArtistAlias.alias_text).in_(upcoming))
            query = query.where(
                or_(func.lower(CanonicalArtist.canonical_name).in_(upcoming), CanonicalArtist.id.in_(aliased))
            )
        rows = (await db.execute(query.order_by(CanonicalArtist.canonical_name))).all()
    return [tuple(r) for r in rows]


async def run(dry_run: bool, include_all: bool, limit: int | None) -> None:
    targets = await _targets(include_all)
    if limit is not None:
        targets = targets[:limit]
    scope = "전체" if include_all else "진행 예정 공연 아티스트만"
    print(f"사진 없는 아티스트 {len(targets)}명 ({scope})" + (" - dry-run" if dry_run else ""))
    if dry_run:
        for _, name in targets:
            print(f"  {name}")
        return

    filled = 0
    async with httpx.AsyncClient(timeout=10.0) as client:
        for i, (canonical_id, name) in enumerate(targets, 1):
            async with AsyncSessionLocal() as db:
                canonical = await db.get(CanonicalArtist, canonical_id)
                await register_artist_image(db, canonical, client)
                found = canonical.profile_image_url
                if found:
                    await db.commit()
                    filled += 1
            print(f"[{i}/{len(targets)}] {name}: {'채움 ' + found if found else '없음'}")

    print(f"\n결과: 채움 {filled}, 없음 {len(targets) - filled}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="대상만 출력하고 아무것도 바꾸지 않음")
    parser.add_argument("--all", action="store_true", help="진행 예정 공연이 없는 아티스트도 포함")
    parser.add_argument("--limit", type=int, help="앞에서부터 N명만")
    args = parser.parse_args()
    asyncio.run(run(args.dry_run, args.all, args.limit))


if __name__ == "__main__":
    main()
