"""티켓이 등록된 기존 공연(모든 계정)의 예상 셋리에 대표곡을 일괄 적용하는 스크립트.

예상 셋리는 티켓 등록 시점에만 자동 생성돼서, 대표곡 기능 배포 전에 등록된 공연은 과거 셋리가 없는
아티스트가 빈 채로 남아 있음. 세 가지 명령:

  scan  - 곡이 빈 아티스트가 있는 공연의 예상 셋리를 다시 생성(Setlist.fm -> 대표곡 -> iTunes 후보가
          1명이면 자동 확정까지 generate_pre_setlist가 처리). 그래도 빈 아티스트 중 iTunes 후보가 있는
          경우(동명이인 여럿, 밴드 멤버 등)는 후보(장르/대표곡)와 함께 검토 파일로 모음
  apply - 검토 파일의 "answer"대로 확정하고 그 아티스트가 나오는 공연들의 예상 셋리를 다시 생성
          answer: 후보의 itunes_artist_id(그 아티스트로 확정) | "none"(대표곡 해당 없음 - iTunes/Last.fm
          모두 안 쓰고 자동 확정도 다시 안 함) | "skip" 또는 빈 값(건너뜀)
  set   - 검토 파일 없이 아티스트 하나를 바로 확정(잘못 자동 확정된 걸 되돌릴 때 등)

유저가 직접 수정한 예상 셋리(is_user_edited)는 건드리지 않음.

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/old/backfill_representative_songs.py scan --dry-run   # 대상만 확인
    venv/bin/python3 scripts/old/backfill_representative_songs.py scan
    (검토 파일 scripts/old/representative_review.json의 각 "answer"를 채운 뒤)
    venv/bin/python3 scripts/old/backfill_representative_songs.py apply --dry-run
    venv/bin/python3 scripts/old/backfill_representative_songs.py apply
    venv/bin/python3 scripts/old/backfill_representative_songs.py set --artist 이재경 --answer none
"""

import argparse
import asyncio
import json
import sys
from pathlib import Path

_BACKEND_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_BACKEND_ROOT))

from fastapi import HTTPException  # noqa: E402
from sqlalchemy import select  # noqa: E402

from app.core.database import AsyncSessionLocal, engine  # noqa: E402
from app.models.concert import Concert  # noqa: E402
from app.models.setlist import PreSetlist  # noqa: E402
from app.models.ticket import Ticket  # noqa: E402
from app.services.artist_normalization import find_canonical_by_alias  # noqa: E402
from app.services.pre_setlist import generate_pre_setlist  # noqa: E402
from app.services.representative_songs import (  # noqa: E402
    NO_ITUNES_ANCHOR,
    _save_anchor,
    fetch_itunes_artist_name,
    search_itunes_artists,
)

engine.echo = False  # 서버 설정이 SQL을 전부 찍어서 진행 로그가 묻힘

# Setlist.fm/iTunes 레이트리밋(iTunes는 분당 약 20회) 여유를 두려고 공연 사이에 쉼
_DELAY_SECONDS = 3.0
_RETRY_DELAY_SECONDS = 30.0
_DEFAULT_REVIEW = _BACKEND_ROOT / "scripts/old/representative_review.json"


# 공연 아티스트 중 예상 셋리에 곡이 하나도 없는 아티스트 - 단독은 songs가 비었으면 그 1명,
# 페스티벌은 artist 태그가 붙은 곡이 없는 아티스트
def _missing_artists(concert: Concert, pre_setlist: PreSetlist | None) -> list[str]:
    artists = [a for a in (concert.artist_name or []) if a and a.strip()]
    songs = pre_setlist.songs if pre_setlist is not None else []
    if len(artists) <= 1:
        return artists if not songs else []
    tagged = {song.get("artist") for song in songs}
    return [a for a in artists if a not in tagged]


# 티켓이 하나라도 등록된 공연(모든 계정) + 그 공연의 예상 셋리 row
async def _ticketed_concerts() -> list[tuple[Concert, PreSetlist | None]]:
    async with AsyncSessionLocal() as db:
        concert_ids = select(Ticket.concert_id).where(Ticket.concert_id.is_not(None)).distinct()
        result = await db.execute(
            select(Concert, PreSetlist)
            .outerjoin(PreSetlist, PreSetlist.concert_id == Concert.id)
            .where(Concert.id.in_(concert_ids))
            .order_by(Concert.start_date)
        )
        return list(result.all())


async def _clear_stale_songs(concert_id) -> None:
    async with AsyncSessionLocal() as db:
        pre_setlist = (
            await db.execute(select(PreSetlist).where(PreSetlist.concert_id == concert_id))
        ).scalar_one_or_none()
        if pre_setlist is not None and not pre_setlist.is_user_edited and pre_setlist.songs:
            pre_setlist.songs = []
            await db.commit()


# 404("채울 데이터 없음")면 예전에 채운 곡이 남지 않게 비움(유저 수정본 제외). Setlist.fm
# 레이트리밋(502로 올라옴)은 한 번 쉬었다 재시도하고, 그래도 실패하면 False
async def _regenerate(concert_id) -> bool:
    for attempt in range(2):
        async with AsyncSessionLocal() as db:
            try:
                await generate_pre_setlist(db, concert_id)
                return True
            except HTTPException as e:
                if e.status_code == 404:
                    await _clear_stale_songs(concert_id)
                    return True
        if attempt == 0:
            await asyncio.sleep(_RETRY_DELAY_SECONDS)
    return False


async def _anchor_status(artist: str) -> str | None:
    async with AsyncSessionLocal() as db:
        canonical = await find_canonical_by_alias(db, artist)
        return canonical.anchor_confirmed_by if canonical is not None else None


async def scan(review_path: Path, dry_run: bool) -> None:
    rows = await _ticketed_concerts()
    targets = []
    for concert, pre_setlist in rows:
        if pre_setlist is not None and pre_setlist.is_user_edited:
            continue
        missing = _missing_artists(concert, pre_setlist)
        if missing:
            targets.append((concert, missing))

    print(f"티켓 등록된 공연 {len(rows)}개 중 빈 아티스트가 있는 공연 {len(targets)}개")
    for concert, missing in targets:
        print(f"  {concert.start_date:%Y-%m-%d} {concert.name} | 빈 아티스트: {', '.join(missing)}")
    if dry_run:
        return

    # 다시 생성(대표곡/자동 확정 포함) 후에도 빈 아티스트를 공연별로 모음
    still_missing: dict[str, list[dict]] = {}
    failed = []
    for i, (concert, _) in enumerate(targets, 1):
        if not await _regenerate(concert.id):
            print(f"[{i}/{len(targets)}] {concert.name}: 생성 실패(Setlist.fm 오류) - 나중에 다시 scan")
            failed.append(concert.name)
            await asyncio.sleep(_DELAY_SECONDS)
            continue
        async with AsyncSessionLocal() as db:
            concert = await db.get(Concert, concert.id)
            pre_setlist = (
                await db.execute(select(PreSetlist).where(PreSetlist.concert_id == concert.id))
            ).scalar_one_or_none()
        missing = _missing_artists(concert, pre_setlist)
        print(f"[{i}/{len(targets)}] {concert.name}: " + (f"여전히 빈 아티스트 {missing}" if missing else "채움"))
        for artist in missing:
            still_missing.setdefault(artist, []).append({"concert_id": str(concert.id), "concert_name": concert.name})
        await asyncio.sleep(_DELAY_SECONDS)

    review, no_candidates, confirmed_none = [], [], []
    for artist, concerts in still_missing.items():
        if await _anchor_status(artist) == NO_ITUNES_ANCHOR:
            confirmed_none.append(artist)  # 이미 "해당 없음"으로 확정 - 다시 묻지 않음
            continue
        candidates = await search_itunes_artists(artist)
        await asyncio.sleep(_DELAY_SECONDS)
        if not candidates:
            no_candidates.append({"artist": artist, "concerts": concerts})
            continue
        review.append({"artist": artist, "answer": None, "concerts": concerts, "candidates": candidates})

    review_path.write_text(
        json.dumps({"review": review, "no_candidates": no_candidates}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(f"\n검토 필요 {len(review)}명, iTunes 후보 없음 {len(no_candidates)}명 -> {review_path}")
    for entry in review:
        print(f"\n== {entry['artist']} ({', '.join(c['concert_name'] for c in entry['concerts'])})")
        for c in entry["candidates"]:
            mark = "*" if c["exact_match"] else " "
            print(f"  {mark} {c['itunes_artist_id']:>12}  {c['artist_name']} ({c['genre']}) {' · '.join(c['top_songs'])}")
    if no_candidates:
        print("\niTunes 후보 없음: " + ", ".join(entry["artist"] for entry in no_candidates))
    if confirmed_none:
        print("이미 '해당 없음'으로 확정: " + ", ".join(confirmed_none))
    if failed:
        print("\n생성 실패(다시 scan 하면 이 공연들만 다시 대상이 됨): " + ", ".join(failed))


# 답 하나를 확정하고 그 아티스트가 나오는 공연들의 예상 셋리를 다시 생성(유저 수정본 제외)
async def _apply_answer(artist: str, answer: str, concerts: list[dict], dry_run: bool) -> None:
    if answer.lower() == NO_ITUNES_ANCHOR:
        itunes_artist_id, confirmed_by, label = None, NO_ITUNES_ANCHOR, "해당 없음"
    else:
        itunes_artist_id, confirmed_by = answer, "admin"
        label = await fetch_itunes_artist_name(itunes_artist_id)
        if label is None:
            print(f"  ✗ {artist}: iTunes 아티스트 {itunes_artist_id}를 찾을 수 없음 - 건너뜀")
            return
    print(f"  {artist} -> {label}" + (f" ({itunes_artist_id})" if itunes_artist_id else "") + f", 공연 {len(concerts)}개")
    if dry_run:
        return

    async with AsyncSessionLocal() as db:
        await _save_anchor(db, artist, itunes_artist_id, confirmed_by=confirmed_by)
    for c in concerts:
        async with AsyncSessionLocal() as db:
            pre_setlist = (
                await db.execute(select(PreSetlist).where(PreSetlist.concert_id == c["concert_id"]))
            ).scalar_one_or_none()
        if pre_setlist is not None and pre_setlist.is_user_edited:
            print(f"     - {c['concert_name']}: 유저 수정본이라 건너뜀")
            continue
        ok = await _regenerate(c["concert_id"])
        print(f"     - {c['concert_name']}: " + ("다시 생성" if ok else "생성 실패(Setlist.fm 오류)"))
        await asyncio.sleep(_DELAY_SECONDS)


async def apply(review_path: Path, dry_run: bool) -> None:
    data = json.loads(review_path.read_text(encoding="utf-8"))
    answered = [e for e in data["review"] if e.get("answer") and str(e["answer"]).lower() != "skip"]
    print(f"검토 {len(data['review'])}명 중 답이 있는 {len(answered)}명 반영" + (" (dry-run)" if dry_run else ""))
    for entry in answered:
        await _apply_answer(entry["artist"], str(entry["answer"]), entry["concerts"], dry_run)


async def set_one(artist: str, answer: str, dry_run: bool) -> None:
    concerts = [
        {"concert_id": str(concert.id), "concert_name": concert.name}
        for concert, _ in await _ticketed_concerts()
        if artist in (concert.artist_name or [])
    ]
    await _apply_answer(artist, answer, concerts, dry_run)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("scan", "apply"):
        p = sub.add_parser(name)
        p.add_argument("--review", type=Path, default=_DEFAULT_REVIEW)
        p.add_argument("--dry-run", action="store_true")
    p = sub.add_parser("set")
    p.add_argument("--artist", required=True, help="공연에 적힌 아티스트 표기 그대로")
    p.add_argument("--answer", required=True, help='iTunes 아티스트 ID 또는 "none"')
    p.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if args.command == "scan":
        asyncio.run(scan(args.review, args.dry_run))
    elif args.command == "apply":
        asyncio.run(apply(args.review, args.dry_run))
    else:
        asyncio.run(set_one(args.artist, args.answer, args.dry_run))


if __name__ == "__main__":
    main()
