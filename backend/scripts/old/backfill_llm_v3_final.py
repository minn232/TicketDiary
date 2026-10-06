"""v3 LLM 아티스트 추출 결과 - 실제 웹훅 파이프라인의 남은 뒷단 실행.

8/27 apply_llm_v3_preview.py로 운영 DB에 넣어둔 v3 결과(artist_name/lineup)는 실제
웹훅(receive_artist_extraction_result)이 하는 일 중 "LLM이 보낸 이름을 merge해서 저장"
까지만 재현한 것이었고, 그 뒷단 - MusicBrainz/fuzzy 정규화 큐잉 - 은 빠져 있었다. 즉
지금 이 콘서트들의 artist_name/lineup은 "LLM에서 받은 상태"에 머물러 있을 뿐, 아직
MusicBrainz 정규화를 거치지 않았다(정규화 배치가 별도의 ArtistNormalizationStatus
테이블을 큐로 쓰는데, 거기 pending row 자체가 없어서 매일 밤 배치가 이 콘서트들을 아예
보지 못하는 상태).

그래서 이 스크립트는 crawl.py의 receive_artist_extraction_result 웹훅이 아티스트 저장
뒤에 실제로 하는 뒷단 처리를 그대로 재현한다:
  - queue_for_normalization (app/services/artist_normalization.py) - concert.artist_name +
    라인업 표기를 MusicBrainz 정규화 대기열(pending)에 적립 → 이후 매일 17:10 배치
    (normalize_pending_artists, 하루 500건)가 실제 MusicBrainz 매칭/fuzzy 정리를 수행함.
    이게 이번 백필의 핵심 - 이 큐잉이 없으면 정규화가 영원히 실행되지 않는다.
  - create_news_feeds_for_concert (app/services/kopis.py) - 팔로워 뉴스피드 생성
  - backfill_first_last_day_from_concert (app/services/ticket.py) - 티켓 첫콘/막콘 재계산

대상 콘서트 목록은 apply_llm_v3_preview.py가 실제로 변경했던 콘서트만 기록해둔 백업
파일(scripts/v3_import/backup_*.json)에서 가져온다 - 그 파일에 있는 concert_id들이 곧
"이번에 artist_name/lineup이 바뀐 콘서트" 목록이기 때문.

큐잉/뉴스피드 둘 다 멱등(idempotent) - queue_for_normalization은 이미 큐잉된
(concert_id, artist_text) 조합을 조용히 스킵, 뉴스피드도 기존 항목 조회 후 없는 것만
추가. 여러 번 실행해도 안전함.

주의: 뉴스피드 생성은 되돌리기 스크립트가 없다(추가만 하는 작업이라 안전하다고 보고
설계함). 팔로워 입장에서는 실제로는 며칠 전부터 있던 콘서트가 "새 소식"으로 뜨게 됨 -
이 부분이 걸리면 먼저 사용자에게 확인할 것.

사용법 (서버에서, backend/ 기준):
    # 1) dry-run으로 몇 건이나 처리될지 먼저 확인 (DB에 아무 변경도 안 함)
    venv/bin/python3 scripts/old/backfill_llm_v3_final.py --dry-run

    # 2) 실제 반영
    venv/bin/python3 scripts/old/backfill_llm_v3_final.py
"""

import argparse
import asyncio
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from sqlalchemy import select  # noqa: E402

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.concert import Concert  # noqa: E402
from app.models.lineup import ConcertLineup  # noqa: E402
from app.services.artist_normalization import queue_for_normalization  # noqa: E402
from app.services.kopis import _build_follow_index, create_news_feeds_for_concert  # noqa: E402
from app.services.ticket import backfill_first_last_day_from_concert  # noqa: E402

_IMPORT_DIR = Path(__file__).resolve().parent / "v3_import"


async def run(backup_path: Path, dry_run: bool) -> None:
    entries = json.loads(backup_path.read_text(encoding="utf-8"))
    concert_ids = [e["concert_id"] for e in entries]
    print(f"백업 파일 기준 대상 콘서트: {len(concert_ids)}건")

    async with AsyncSessionLocal() as db:
        follow_index = await _build_follow_index(db)

        not_found = 0
        queued_concerts = 0
        queued_names_total = 0
        feed_created_concerts = 0
        feed_entries_total = 0
        ticket_backfilled_concerts = 0

        for concert_id in concert_ids:
            result = await db.execute(select(Concert).where(Concert.id == concert_id))
            concert = result.scalar_one_or_none()
            if concert is None:
                not_found += 1
                continue

            # 실제 웹훅과 동일하게 concert.artist_name + 라인업 표기를 합쳐서 큐잉
            queue_names = set(concert.artist_name or [])
            lineup_result = await db.execute(
                select(ConcertLineup.artist).where(ConcertLineup.concert_id == concert.id)
            )
            queue_names |= set(lineup_result.scalars().all())

            if queue_names:
                if not dry_run:
                    await queue_for_normalization(db, concert.id, list(queue_names), commit=False)
                queued_concerts += 1
                queued_names_total += len(queue_names)

            matched = await create_news_feeds_for_concert(db, concert, follow_index=follow_index)
            if matched:
                feed_created_concerts += 1
                feed_entries_total += len(matched)

            if not dry_run:
                await backfill_first_last_day_from_concert(db, concert.id)
                ticket_backfilled_concerts += 1

        if not dry_run:
            await db.commit()

        print(f"DB에서 콘서트를 못 찾음: {not_found}건")
        print(f"MusicBrainz 정규화 큐잉 대상 콘서트: {queued_concerts}건 (표기 {queued_names_total}개, 중복 큐잉은 자동 스킵됨)")
        print(f"뉴스피드 생성 대상 콘서트: {feed_created_concerts}건 (총 {feed_entries_total}개 항목)")
        if dry_run:
            print("[dry-run] 큐잉/티켓 첫콘·막콘 재계산은 건너뜀, DB에 아무 변경도 하지 않았습니다.")
        else:
            print(f"티켓 첫콘/막콘 재계산 실행한 콘서트: {ticket_backfilled_concerts}건")
            print("큐잉된 표기는 오늘 밤 17:10 배치(normalize_pending_artists, 하루 500건)부터 순차 처리됩니다.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--backup",
        default=None,
        help="apply_llm_v3_preview.py가 남긴 백업 JSON 경로 (기본: v3_import 안에서 가장 최근 backup_*.json 자동 탐색)",
    )
    parser.add_argument("--dry-run", action="store_true", help="DB를 건드리지 않고 처리 예상 건수만 출력")
    args = parser.parse_args()

    if args.backup:
        backup_path = Path(args.backup)
    else:
        candidates = sorted(_IMPORT_DIR.glob("backup_*.json"))
        if not candidates:
            print(f"백업 파일을 찾을 수 없습니다: {_IMPORT_DIR}/backup_*.json")
            sys.exit(1)
        backup_path = candidates[-1]
        print(f"백업 파일 자동 선택: {backup_path}")

    asyncio.run(run(backup_path, args.dry_run))


if __name__ == "__main__":
    main()
