"""[크롤링/KOPIS로만 들어온 아티스트명이 정규화 큐에 아예 안 들어갔던 구조적 갭 백필]

/crawl-result 웹훅이 아티스트명을 병합만 하고 queue_for_normalization을 호출 안 해서
(2026-09-09 수정, app/api/v1/endpoints/crawl.py), 크롤링이나 KOPIS로만 채워진 아티스트명은
artist_normalization_status에 한 번도 안 들어간 채 원문 그대로 영구히 남아있었다("HANRORO"가
canonical "한로로"로 안 바뀌던 실사례로 발견). 이 스크립트는 코드 수정 이전에 이미 이렇게
누락된 기존 표기들을 한 번에 큐에 적립한다(pending row 추가만, MusicBrainz 조회는 안 함).

사용법:
    cd backend
    python scripts/old/backfill_unqueued_artist_names.py --dry-run   # 대상 건수만 확인
    python scripts/old/backfill_unqueued_artist_names.py             # 실제 큐잉

큐잉만 하고 끝나므로, 이어서 catch_up_normalize_backlog.py로 실제 MusicBrainz 조회/치환을 진행할 것.
"""
import argparse
import asyncio
import logging
import sys
from pathlib import Path
from uuid import UUID

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from sqlalchemy import select  # noqa: E402

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.artist_normalization import ArtistNormalizationStatus  # noqa: E402
from app.models.concert import Concert  # noqa: E402
from app.models.lineup import ConcertLineup  # noqa: E402
from app.services.artist_normalization import queue_for_normalization  # noqa: E402

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


# concert_id -> 아직 정규화 큐에 안 들어간 표기 집합. concerts.artist_name과
# concert_lineups.artist(웹훅이 같이 큐잉하는 것과 동일 범위) 둘 다 대상으로 함
async def _find_unqueued() -> dict[UUID, set[str]]:
    async with AsyncSessionLocal() as db:
        names_by_concert: dict[UUID, set[str]] = {}

        concert_result = await db.execute(
            select(Concert.id, Concert.artist_name).where(Concert.artist_name != [])
        )
        for concert_id, artist_name in concert_result.all():
            names_by_concert.setdefault(concert_id, set()).update(artist_name or [])

        lineup_result = await db.execute(select(ConcertLineup.concert_id, ConcertLineup.artist))
        for concert_id, artist in lineup_result.all():
            names_by_concert.setdefault(concert_id, set()).add(artist)

        if not names_by_concert:
            return {}

        queued_result = await db.execute(
            select(ArtistNormalizationStatus.concert_id, ArtistNormalizationStatus.artist_text).where(
                ArtistNormalizationStatus.concert_id.in_(names_by_concert.keys())
            )
        )
        already_queued: dict[UUID, set[str]] = {}
        for concert_id, artist_text in queued_result.all():
            already_queued.setdefault(concert_id, set()).add(artist_text)

        unqueued: dict[UUID, set[str]] = {}
        for concert_id, names in names_by_concert.items():
            missing = {n.strip() for n in names if n and n.strip()} - already_queued.get(concert_id, set())
            if missing:
                unqueued[concert_id] = missing
        return unqueued


async def main(dry_run: bool) -> None:
    unqueued = await _find_unqueued()
    total_names = sum(len(v) for v in unqueued.values())
    print(f"대상: 공연 {len(unqueued)}건, 표기 {total_names}건")

    if dry_run:
        print("--dry-run이라 여기서 종료(DB 반영 없음).")
        return

    async with AsyncSessionLocal() as db:
        for i, (concert_id, names) in enumerate(unqueued.items(), 1):
            await queue_for_normalization(db, concert_id, list(names), commit=False)
            if i % 100 == 0:
                await db.commit()
                print(f"  {i}/{len(unqueued)}건 처리...")
        await db.commit()

    print(f"완료: 공연 {len(unqueued)}건, 표기 {total_names}건 큐잉함.")
    print("다음: python scripts/old/catch_up_normalize_backlog.py 로 실제 MusicBrainz 조회/치환 진행.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="대상 건수만 출력하고 DB엔 반영 안 함")
    args = parser.parse_args()
    asyncio.run(main(args.dry_run))
