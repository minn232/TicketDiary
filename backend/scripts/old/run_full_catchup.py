"""정규화 밀린 분 전체 + 아티스트 사진 백필을 순서대로 한 번에 돌리는 일회성 스크립트
(2026-09-07 정규화 배치가 좀비 커넥션에 막혀 밀린 분을 서버 배포 뒤 한 번에 처리하려고 작성).

1) normalize_pending_artists(limit=99999)로 pending 전부 정규화(이제 건당 커밋이라 중간에
   끊겨도 그때까지 처리분은 안전하게 남음 - artist_normalization.py의 commit_each_row 참고).
2) 이어서 backfill_artist_images.py와 같은 로직으로 mbid 있는 canonical_artists 전부의
   사진을 채움(이미 그 스크립트 자체가 25건마다 커밋해서 안전함).

재워두고 자고 일어나서 확인하는 용도라, 각 단계 시작/종료를 타임스탬프와 함께 출력하고
한쪽이 실패해도(예: 정규화 중 예상 밖 오류) 사진 백필은 그대로 이어서 시도합니다.

사용법(백그라운드로 돌려두고 로그아웃해도 계속 실행되게):
    cd backend
    nohup python scripts/old/run_full_catchup.py > /tmp/run_full_catchup.log 2>&1 &
    disown
    tail -f /tmp/run_full_catchup.log   # 진행 상황 확인
"""
import asyncio
import logging
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

import httpx  # noqa: E402
from sqlalchemy import select  # noqa: E402

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.artist_normalization import CanonicalArtist  # noqa: E402
from app.services.artist_normalization import (  # noqa: E402
    _register_artist_image,
    normalize_pending_artists,
)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

_IMAGE_COMMIT_EVERY = 25


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


async def _run_normalize() -> None:
    print(f"[{_now()}] 1/2 정규화 시작(pending 전부)")
    try:
        stats = await normalize_pending_artists(limit=99999)
        print(f"[{_now()}] 1/2 정규화 완료: {stats}")
    except Exception as e:
        # 여기서 죽어도 사진 백필(2단계)은 그대로 진행 - 이미 matched된
        # 아티스트 사진 채우는 건 정규화 성공 여부와 무관함.
        logger.error(f"정규화 중 예상 밖 오류(사진 백필은 계속 진행): {e}")
        print(f"[{_now()}] 1/2 정규화 오류(계속 진행): {e}")


async def _run_image_backfill() -> None:
    print(f"[{_now()}] 2/2 아티스트 사진 백필 시작")
    async with AsyncSessionLocal() as db:
        canonicals = (
            (await db.execute(select(CanonicalArtist).where(CanonicalArtist.mbid.isnot(None))))
            .scalars()
            .all()
        )
        print(f"  mbid 있는 canonical_artists {len(canonicals)}건 대상")

        async with httpx.AsyncClient(timeout=10.0) as client:
            added = 0
            for i, canonical in enumerate(canonicals, start=1):
                before = canonical.profile_image_url
                try:
                    await _register_artist_image(db, canonical, client)
                except Exception as e:
                    logger.warning(f"사진 조회 실패, 건너뜀 (canonical={canonical.canonical_name!r}): {e}")
                    continue
                if before is None and canonical.profile_image_url is not None:
                    added += 1

                if i % _IMAGE_COMMIT_EVERY == 0:
                    print(f"  ...{i}/{len(canonicals)} 처리, 지금까지 {added}건 추가")
                    await db.commit()

        await db.commit()
        print(f"[{_now()}] 2/2 사진 백필 완료: {added}건 신규 추가")


async def main() -> None:
    print(f"[{_now()}] 전체 캐치업 시작")
    await _run_normalize()
    await _run_image_backfill()
    print(f"[{_now()}] 전체 캐치업 끝")


if __name__ == "__main__":
    asyncio.run(main())
