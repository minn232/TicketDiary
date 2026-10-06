"""llm_server/test_batch_extract.py로 pod에서 직접 돌린 57건(artist_extraction_targets.csv)의
결과(batch_results_target/<kopis_id>.json)를 정식 /artist-result 웹훅과 동일한 로직으로 DB에
반영하는 일회용 스크립트. 이 배치는 웹훅 경로를 안 거쳐서(crawl.py의 receive_artist_extraction_result
참고) 자동으로는 아무것도 반영 안 됨 - 아티스트명 병합/정규화 큐잉/즉시 정규화 시도/event_type
승격/뉴스피드 소급생성까지 웹훅과 동일하게 재현한다(로직은 직접 재구현하지 않고 그대로 import해서 씀).

raw json은 llm_server/normalize.py의 normalize_artist_list/normalize_event_type/
normalize_lineup_entries로 먼저 다듬는다(main.py의 _process_artist_batch가 실제로 하는 것과
동일) - test_batch_extract.py 자체의 단순 `[e.get("artist") ...]` 추출은 블록리스트/중복제거/
FESTIVAL+1 안전장치를 안 거치므로 여기서는 쓰지 않음.

수동 정정 3건(이 세션에서 원본 포스터 없이 concert_name 대조만으로 확인, 부제를 아티스트로
오인한 패턴):
  - PF242732 "유발이 단독공연, 그녀의 일기장을 훔쳐봐주세요": 부제를 두 번째 아티스트로 오추출 -> "유발이" 단독
  - PF243010 "박소은 단독 공연, ... 오 너와 나 그렇게 쌓여가는 너와 나": 위와 동일 패턴 -> "박소은" 단독
  - PF243143 "OAH! (오아!) 단독 공연: Sweet dreams, May": 부제만 뽑고 실제 아티스트명을 놓침 ->
    DB에 이미 있는 표기("OAH!", 다른 콘서트 2건에서 확인)로 정정

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/old/apply_manual_artist_extraction_batch.py \
        --targets-csv scripts/old/manual_batch_data/artist_extraction_targets.csv \
        --results-dir scripts/old/manual_batch_data/batch_results_target \
        --dry-run   # 먼저 반영 없이 변경 예정 내역만 확인
    (동일 명령에서 --dry-run 빼면 실제 반영 + MusicBrainz 즉시 정규화 + attempted_at 기록까지 수행)
"""

import argparse
import asyncio
import csv
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

_BACKEND_ROOT = Path(__file__).resolve().parent.parent.parent
_REPO_ROOT = _BACKEND_ROOT.parent
sys.path.insert(0, str(_BACKEND_ROOT))
sys.path.insert(0, str(_REPO_ROOT / "llm_server"))

from sqlalchemy import select, update  # noqa: E402

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.concert import Concert  # noqa: E402
from app.models.lineup import ConcertLineup  # noqa: E402
from app.services.artist_matching import get_known_artist_names, merge_or_replace_solo_seed  # noqa: E402
from app.services.artist_normalization import normalize_specific_artists, queue_for_normalization  # noqa: E402
from app.services.kopis import create_news_feeds_for_concert  # noqa: E402
from app.services.lineup import upsert_concert_lineup  # noqa: E402
from app.services.ticket import backfill_first_last_day_from_concert, upgrade_event_type_if_multi_artist  # noqa: E402
from normalize import normalize_artist_list, normalize_event_type, normalize_lineup_entries  # noqa: E402

_MANUAL_OVERRIDES: dict[str, dict] = {
    "PF242732": {"lineup": [{"artist": "유발이", "performance_date": None}], "event_type": "SOLO"},
    "PF243010": {"lineup": [{"artist": "박소은", "performance_date": None}], "event_type": "SOLO"},
    "PF243143": {"lineup": [{"artist": "OAH!", "performance_date": None}], "event_type": "SOLO"},
}

# PF299785(44인 힙합 페스티벌)에서 두 아티스트 이름이 구분자 없이 그대로 붙어 나온 3건 - DB에
# "AKMU"/"한로로"/"EK"/"Royal 44"/"제네 더 질라"가 이미 각각 별도 아티스트로 존재하는 걸
# 직접 확인함(예전 "HANRORO" 버그와 같은 유형). "New Ambition"은 DB에 선례가 없어 불확실하지만,
# 붙여둔 채로 두는 것보단 분리하는 쪽이 안전(분리해도 확인대기로만 남고 기존 정상 매칭을 해치지 않음)
_SPLIT_CONCATENATED_ARTISTS: dict[str, list[str]] = {
    "AKMU HANRORO": ["AKMU", "한로로"],
    "EK Royal 44": ["EK", "Royal 44"],
    "NEW AMBITION ZENE THE ZILLA": ["New Ambition", "Zene The Zilla"],
}


def _split_concatenated_lineup(raw: dict) -> dict:
    lineup = raw.get("lineup")
    if not lineup:
        return raw
    new_lineup = []
    changed = False
    for entry in lineup:
        parts = _SPLIT_CONCATENATED_ARTISTS.get((entry.get("artist") or "").strip())
        if parts:
            changed = True
            new_lineup.extend({"artist": p, "performance_date": entry.get("performance_date")} for p in parts)
        else:
            new_lineup.append(entry)
    if not changed:
        return raw
    return {**raw, "lineup": new_lineup}


async def _process_one(db, concert: Concert, raw: dict, concert_name: str, known_names: set[str], dry_run: bool) -> str:
    artist_name = normalize_artist_list(raw, concert_name)
    event_type = normalize_event_type(raw)
    lineup_entries = normalize_lineup_entries(raw, concert_name)

    before = list(concert.artist_name or [])
    merged = merge_or_replace_solo_seed(concert, artist_name, known_names) if artist_name else before
    artist_changed = merged != before

    if dry_run:
        return (
            f"{concert.kopis_id}: artist_name {before} -> {merged if artist_changed else before} "
            f"(event_type_hint={event_type}, lineup_entries={len(lineup_entries)})"
        )

    changed_fields = []
    upgraded = False
    if artist_changed:
        concert.artist_name = merged
        concert.admin_reviewed_at = None
        upgraded = upgrade_event_type_if_multi_artist(concert, event_type)
        changed_fields.append("artist_name")

    if lineup_entries:
        lineup_known = set(known_names) | set(concert.artist_name or before)
        lineup_changed = await upsert_concert_lineup(
            db, concert.id, lineup_entries, source="poster", known_names=lineup_known, commit=False
        )
        if lineup_changed:
            changed_fields.append("lineup")

    if changed_fields:
        await db.commit()

    if "artist_name" in changed_fields:
        await db.refresh(concert)
        await create_news_feeds_for_concert(db, concert)
        await db.commit()
        if upgraded:
            await backfill_first_last_day_from_concert(db, concert.id)

    queue_names = set(concert.artist_name or [])
    if lineup_entries:
        lineup_result = await db.execute(select(ConcertLineup.artist).where(ConcertLineup.concert_id == concert.id))
        queue_names |= set(lineup_result.scalars().all())

    stats = {}
    if queue_names:
        await queue_for_normalization(db, concert.id, list(queue_names))
        stats = await normalize_specific_artists(concert.id, list(queue_names))

    return f"{concert.kopis_id}: artist_name {before} -> {concert.artist_name} changed={changed_fields} normalize={stats}"


async def main(targets_csv: Path, results_dir: Path, dry_run: bool) -> None:
    with open(targets_csv, encoding="utf-8") as f:
        targets = {row["kopis_id"]: row["concert_name"] for row in csv.DictReader(f)}

    result_files = sorted(results_dir.glob("*.json"))
    print(f"대상 {len(targets)}건, 결과 파일 {len(result_files)}건 (dry_run={dry_run})")

    async with AsyncSessionLocal() as db:
        known_names = await get_known_artist_names(db)
        print(f"기존 known_artist_names {len(known_names)}개 로드")

        processed_kopis_ids: list[str] = []
        for f in result_files:
            kopis_id = f.stem
            if kopis_id not in targets:
                print(f"  [SKIP] {kopis_id}: targets.csv에 없음")
                continue
            raw = json.loads(f.read_text(encoding="utf-8"))
            if kopis_id in _MANUAL_OVERRIDES:
                print(f"  [OVERRIDE] {kopis_id}: 수동 정정 적용")
                raw = {**raw, **_MANUAL_OVERRIDES[kopis_id]}
            split_raw = _split_concatenated_lineup(raw)
            if split_raw is not raw:
                print(f"  [SPLIT] {kopis_id}: 구분자 없이 붙은 아티스트명 분리")
                raw = split_raw

            result = await db.execute(select(Concert).where(Concert.kopis_id == kopis_id))
            concert = result.scalar_one_or_none()
            if concert is None:
                print(f"  [SKIP] {kopis_id}: DB에 concert 없음")
                continue

            msg = await _process_one(db, concert, raw, targets[kopis_id], known_names, dry_run)
            print(f"  {msg}")
            processed_kopis_ids.append(kopis_id)

        if not dry_run and processed_kopis_ids:
            # 이 배치는 웹훅 경로를 안 거쳐서 attempted_at이 지금까지 비어있었음(확인함) -
            # 정식 send_posters_for_artist_extraction과 동일한 값을 기록해 쿨다운/재시도 계산에 반영
            now = datetime.now(timezone.utc)
            res = await db.execute(
                update(Concert)
                .where(Concert.kopis_id.in_(processed_kopis_ids))
                .values(
                    artist_extraction_attempted_at=now,
                    artist_extraction_attempt_count=Concert.artist_extraction_attempt_count + 1,
                )
            )
            await db.commit()
            print(f"attempted_at 기록: {res.rowcount}건")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--targets-csv", required=True, type=Path)
    parser.add_argument("--results-dir", required=True, type=Path)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    asyncio.run(main(args.targets_csv, args.results_dir, args.dry_run))
