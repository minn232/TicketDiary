"""아티스트 사진 소급 백필 - register_artist_image(mbid -> Spotify/Wikidata 사진) 기능이
배포되기 전에 이미 matched된 canonical_artists는 자동으로 혜택을 못 받는다(재매치 트리거가
없어서). mbid가 있는 canonical_artists 전부 순회하며 사진을 채워준다. 이미 확정된 mbid를
그대로 조회하는 것뿐이라 새로운 오매칭 위험은 없음(이름 검색 아님).

MusicBrainz 요청 제한(초당 1회, 2초 간격 스로틀)에 걸려 mbid 건수만큼 시간이 걸림 - 정규화
배치와 비슷하게 수천 건이면 1~2시간 이상 걸릴 수 있으니 백그라운드로 돌려두는 걸 권장.

사용법:
    cd backend
    python scripts/backfill_artist_images.py --dry-run   # 미리 확인(DB 미반영)
    python scripts/backfill_artist_images.py             # 실제 실행
"""
import argparse
import asyncio
import logging
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

import httpx
from sqlalchemy import select

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.artist_normalization import CanonicalArtist  # noqa: E402
from app.services.artist_normalization import register_artist_image  # noqa: E402

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

_COMMIT_EVERY = 25


async def main(dry_run: bool) -> None:
    async with AsyncSessionLocal() as db:
        canonicals = (
            (await db.execute(select(CanonicalArtist).where(CanonicalArtist.mbid.isnot(None))))
            .scalars()
            .all()
        )
        print(f"mbid 있는 canonical_artists {len(canonicals)}건 대상")

        async with httpx.AsyncClient(timeout=10.0) as client:
            added = 0
            for i, canonical in enumerate(canonicals, start=1):
                before = canonical.profile_image_url
                await register_artist_image(db, canonical, client)
                if before is None and canonical.profile_image_url is not None:
                    added += 1
                    print(f"  + {canonical.canonical_name} -> {canonical.profile_image_url}")

                if i % _COMMIT_EVERY == 0:
                    print(f"  ...{i}/{len(canonicals)} 처리, 지금까지 {added}건 추가")
                    if not dry_run:
                        await db.commit()

        if dry_run:
            await db.rollback()
            print(f"--dry-run이라 DB에는 반영되지 않음. 실제로는 {added}건 추가됐을 것")
        else:
            await db.commit()
            print(f"완료: {added}건 신규 사진 추가")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="DB에 반영하지 않고 결과만 출력")
    args = parser.parse_args()
    asyncio.run(main(args.dry_run))
