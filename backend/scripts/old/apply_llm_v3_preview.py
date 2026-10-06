"""v3(신규 프롬프트) LLM 아티스트 추출 결과를 실서버 DB에 임시로 반영 - 실제 앱에서 어떻게
보이는지 미리 확인하기 위한 일회성 스크립트. 나중에 되돌릴 걸 전제로, 실행 전 상태를 전부
백업 파일로 저장한다.

실제 웹훅(app/api/v1/endpoints/crawl.py의 receive_artist_extraction_result)과 최대한
동일한 로직(merge_artist_names/upgrade_event_type_if_multi_artist/upsert_concert_lineup)을
그대로 재사용하되, 아래 두 부수효과는 "미리보기"라는 목적상 일부러 뺐다:
  - create_news_feeds_for_concert (팔로워 뉴스피드 생성) - 실험용/오탈자 있는 데이터로
    실제 유저 피드에 노출되는 걸 막기 위함
  - backfill_first_last_day_from_concert (기존 티켓 첫콘/막콘 재계산) - 실제 등록된
    티켓 데이터를 건드리지 않기 위함
(옵션 없음 - 필요해지면 코드에 직접 추가할 것)

사용법 (서버에서, backend/ 기준):
    # 1) 먼저 dry-run으로 몇 건이나 매칭되는지 확인 (DB에 아무 변경도 안 함)
    venv/bin/python3 scripts/old/apply_llm_v3_preview.py --dry-run

    # 2) 실제 반영 (백업 파일 자동 생성, 경로가 출력됨)
    venv/bin/python3 scripts/old/apply_llm_v3_preview.py

    # 3) 되돌리기
    venv/bin/python3 scripts/old/apply_llm_v3_preview.py --revert scripts/v3_import/backup_20260827_153000.json
"""

import argparse
import asyncio
import json
import sys
from datetime import date, datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from sqlalchemy import select  # noqa: E402

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.concert import Concert  # noqa: E402
from app.models.lineup import ConcertLineup  # noqa: E402
from app.services.artist_matching import get_known_artist_names, merge_artist_names  # noqa: E402
from app.services.lineup import upsert_concert_lineup  # noqa: E402
from app.services.ticket import upgrade_event_type_if_multi_artist  # noqa: E402

_IMPORT_DIR = Path(__file__).resolve().parent / "v3_import"
sys.path.insert(0, str(_IMPORT_DIR))


def _load_normalize():
    # normalize.py는 llm_server(별도 프로젝트) 소속이라 이 스크립트와 같이
    # v3_import/normalize.py로 복사해둔 사본을 씀(원본과 동기화 필요 시 다시 복사)
    import normalize as _normalize  # type: ignore  # noqa: E402

    return _normalize


async def _backup_concert(db, concert: Concert) -> dict:
    result = await db.execute(select(ConcertLineup).where(ConcertLineup.concert_id == concert.id))
    lineups = result.scalars().all()
    return {
        "concert_id": str(concert.id),
        "kopis_id": concert.kopis_id,
        "name": concert.name,
        "artist_name": list(concert.artist_name or []),
        "event_type": concert.event_type,
        "lineups": [
            {"artist": lu.artist, "performance_date": lu.performance_date.isoformat(), "source": lu.source}
            for lu in lineups
        ],
    }


async def apply(csv_path: Path, results_dir: Path, dry_run: bool) -> None:
    import csv as csv_mod

    normalize = _load_normalize()
    rows = list(csv_mod.DictReader(open(csv_path, encoding="utf-8")))

    backups: list[dict] = []
    matched = 0
    changed = 0
    not_in_db = 0
    no_result_file = 0

    async with AsyncSessionLocal() as db:
        known_artist_names = await get_known_artist_names(db)

        for row in rows:
            kopis_id = row["kopis_id"]
            concert_name = row["concert_name"]
            json_path = results_dir / f"{kopis_id}.json"
            if not json_path.exists():
                no_result_file += 1
                continue

            result = await db.execute(select(Concert).where(Concert.kopis_id == kopis_id))
            concert = result.scalars().first()
            if concert is None:
                not_in_db += 1
                continue
            matched += 1

            raw = json.loads(json_path.read_text(encoding="utf-8"))
            body_artist_name = normalize.normalize_artist_list(raw, concert_name)
            body_event_type = normalize.normalize_event_type(raw)
            body_lineup = normalize.normalize_lineup_entries(raw, concert_name)

            before = await _backup_concert(db, concert)
            row_changed = False

            if body_artist_name:
                replace = concert.kopis_detail_synced_at is not None and len(concert.artist_name or []) < 4
                merged = merge_artist_names(concert.artist_name, body_artist_name, known_artist_names, replace=replace)
                if merged != (concert.artist_name or []):
                    if not dry_run:
                        concert.artist_name = merged
                        upgrade_event_type_if_multi_artist(concert, body_event_type)
                    row_changed = True

            if body_lineup:
                lineup_known_names = set(known_artist_names) | set(concert.artist_name or [])
                if not dry_run:
                    lineup_changed = await upsert_concert_lineup(
                        db, concert.id, body_lineup, source="poster", known_names=lineup_known_names, commit=False
                    )
                    row_changed = row_changed or lineup_changed
                else:
                    row_changed = True  # dry-run이라 실제 upsert는 안 하고 "바뀔 가능성 있음"만 표시

            if row_changed:
                changed += 1
                backups.append(before)
                if not dry_run:
                    await db.commit()

        print(f"CSV 전체: {len(rows)}건")
        print(f"결과 JSON 없음: {no_result_file}건")
        print(f"DB에 kopis_id 매칭 안 됨: {not_in_db}건")
        print(f"매칭됨: {matched}건 / 변경 발생: {changed}건")

    if dry_run:
        print("\n[dry-run] DB에 아무 변경도 하지 않았습니다.")
        return

    _IMPORT_DIR.mkdir(parents=True, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    backup_path = _IMPORT_DIR / f"backup_{ts}.json"
    backup_path.write_text(json.dumps(backups, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"\n백업 저장됨 (되돌릴 때 이 파일 필요): {backup_path}")
    print(f"되돌리려면: python3 scripts/old/apply_llm_v3_preview.py --revert {backup_path}")


async def revert(backup_path: Path) -> None:
    backups = json.loads(backup_path.read_text(encoding="utf-8"))
    restored = 0
    async with AsyncSessionLocal() as db:
        for entry in backups:
            result = await db.execute(select(Concert).where(Concert.id == entry["concert_id"]))
            concert = result.scalar_one_or_none()
            if concert is None:
                print(f"  건너뜀 (콘서트 이미 삭제됨?): {entry['kopis_id']}")
                continue

            concert.artist_name = entry["artist_name"]
            concert.event_type = entry["event_type"]

            # 라인업은 백업 시점 스냅샷으로 완전히 교체(이 스크립트가 새로 추가한 행 제거 +
            # 원래 있던 행 복원)
            await db.execute(
                ConcertLineup.__table__.delete().where(ConcertLineup.concert_id == concert.id)
            )
            for lu in entry["lineups"]:
                db.add(
                    ConcertLineup(
                        concert_id=concert.id,
                        artist=lu["artist"],
                        performance_date=date.fromisoformat(lu["performance_date"]),
                        source=lu["source"],
                    )
                )
            restored += 1

        await db.commit()
    print(f"복원 완료: {restored}/{len(backups)}건")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--csv", default=str(_IMPORT_DIR / "test_concerts_all.csv"))
    parser.add_argument("--results-dir", default=str(_IMPORT_DIR / "batch_results_v3"))
    parser.add_argument("--dry-run", action="store_true", help="DB를 건드리지 않고 매칭/변경 예상 건수만 출력")
    parser.add_argument("--revert", metavar="BACKUP_JSON", help="지정한 백업 파일로 되돌리기")
    args = parser.parse_args()

    if args.revert:
        asyncio.run(revert(Path(args.revert)))
        return

    asyncio.run(apply(Path(args.csv), Path(args.results_dir), args.dry_run))


if __name__ == "__main__":
    main()
