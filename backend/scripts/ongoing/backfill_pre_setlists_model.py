"""기존 예상 셋리스트를 확률 모델 방식으로 다시 생성하는 백필 스크립트.

예상 셋리는 티켓 등록 때 한 번만 만들어져서, 모델 배포 전에 만든 것(빈도순 top20 / 청취자순 대표곡)은
저절로 안 바뀜. 티켓이 등록된 공연 중 아직 모델을 안 거친 예상 셋리(곡에 probability가 없음)를 다시 생성함.

- 유저가 직접 수정한 예상 셋리(is_user_edited)는 건드리지 않음
- 기본은 아직 안 끝난 공연만(종료된 공연은 화면에서 거의 안 보임), --all이면 지난 공연도 포함
- 다시 만들었는데 데이터가 없거나(404) Setlist.fm 오류(502)면 기존 곡을 그대로 유지(generate_pre_setlist는
  404일 때 기존 곡을 비우는데, 백필에서는 좋은 데이터를 잃으면 안 되므로 원래 곡으로 되돌림)
- 실제 셋리 기반이던 곡이 대표곡으로 바뀌는 강등도 막음(Setlist.fm이 일시적으로 비어 있을 때 생김)
- 대표곡만 있던 셋리는 모델을 거쳐도 probability가 안 붙어서 다시 실행하면 또 대상이 됨(같은 결과로 재생성)
- --force: 이미 모델을 거친 것도 대상(모델/규칙을 고친 뒤 다시 만들 때). 유저 수정본은 그대로 제외

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/ongoing/backfill_pre_setlists_model.py --dry-run          # 대상만 확인
    venv/bin/python3 scripts/ongoing/backfill_pre_setlists_model.py --limit 5          # 5개만 먼저
    venv/bin/python3 scripts/ongoing/backfill_pre_setlists_model.py
    venv/bin/python3 scripts/ongoing/backfill_pre_setlists_model.py --all              # 지난 공연 포함
    venv/bin/python3 scripts/ongoing/backfill_pre_setlists_model.py --all --force     # 전부 다시
    venv/bin/python3 scripts/ongoing/backfill_pre_setlists_model.py --concert-id <uuid>
"""

import argparse
import asyncio
import sys
from datetime import datetime, timezone
from pathlib import Path

_BACKEND_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_BACKEND_ROOT))

from fastapi import HTTPException  # noqa: E402
from sqlalchemy import select  # noqa: E402

from app.core.config import settings  # noqa: E402
from app.core.database import AsyncSessionLocal, engine  # noqa: E402
from app.models.concert import Concert  # noqa: E402
from app.models.setlist import PreSetlist  # noqa: E402
from app.models.ticket import Ticket  # noqa: E402
from app.services.pre_setlist import generate_pre_setlist  # noqa: E402

engine.echo = False  # 서버 설정이 SQL을 전부 찍어서 진행 로그가 묻힘

# Setlist.fm/iTunes 레이트리밋 여유를 두려고 공연 사이에 쉼
_DELAY_SECONDS = 3.0
_RETRY_DELAY_SECONDS = 30.0


def _needs_model(pre_setlist: PreSetlist, force: bool) -> bool:
    if pre_setlist.is_user_edited:
        return False
    return force or any(s.get("probability") is None for s in pre_setlist.songs or [])


# 티켓이 하나라도 등록된 공연(모든 계정) 중 모델을 안 거친 예상 셋리가 있는 공연
async def _targets(include_past: bool, concert_id: str | None, force: bool) -> list[tuple[Concert, PreSetlist]]:
    async with AsyncSessionLocal() as db:
        ticketed = select(Ticket.concert_id).where(Ticket.concert_id.is_not(None)).distinct()
        query = (
            select(Concert, PreSetlist)
            .join(PreSetlist, PreSetlist.concert_id == Concert.id)
            .where(Concert.id.in_(ticketed))
            .order_by(Concert.start_date)
        )
        if concert_id:
            query = query.where(Concert.id == concert_id)
        if not include_past:
            query = query.where(Concert.end_date >= datetime.now(timezone.utc))
        rows = (await db.execute(query)).all()
    return [(concert, pre_setlist) for concert, pre_setlist in rows if _needs_model(pre_setlist, force)]


async def _restore_songs(concert_id, songs: list[dict]) -> None:
    async with AsyncSessionLocal() as db:
        pre_setlist = (
            await db.execute(select(PreSetlist).where(PreSetlist.concert_id == concert_id))
        ).scalar_one_or_none()
        if pre_setlist is not None and not pre_setlist.is_user_edited:
            pre_setlist.songs = songs
            await db.commit()


def _has_real_songs(songs: list[dict]) -> bool:
    return any(s.get("source") != "representative" for s in songs)


async def _current_songs(concert_id) -> list[dict]:
    async with AsyncSessionLocal() as db:
        pre_setlist = (
            await db.execute(select(PreSetlist).where(PreSetlist.concert_id == concert_id))
        ).scalar_one_or_none()
        return list(pre_setlist.songs) if pre_setlist is not None else []


# 다시 생성. 성공하면 "생성", 데이터 없음(404)이면 기존 곡을 되돌리고 "유지(데이터 없음)", 실제 셋리 기반
# 곡이 대표곡으로만 바뀌면 되돌리고 "유지(강등 방지)", Setlist.fm 오류(502 등)는 한 번 쉬었다 재시도하고
# 그래도 실패하면 "실패(기존 유지)". 아티스트 정보가 없는 공연(400)은 만들 게 없어서 "건너뜀"
async def _regenerate(concert_id, old_songs: list[dict]) -> str:
    for attempt in range(2):
        async with AsyncSessionLocal() as db:
            try:
                await generate_pre_setlist(db, concert_id)
                if _has_real_songs(old_songs) and not _has_real_songs(await _current_songs(concert_id)):
                    await _restore_songs(concert_id, old_songs)
                    return "유지(강등 방지)"
                return "생성"
            except HTTPException as e:
                if e.status_code == 400:
                    return "건너뜀(아티스트 없음)"
                if e.status_code == 404:
                    await _restore_songs(concert_id, old_songs)
                    return "유지(데이터 없음)"
        if attempt == 0:
            await asyncio.sleep(_RETRY_DELAY_SECONDS)
    return "실패(기존 유지)"


async def _song_count(concert_id) -> int:
    async with AsyncSessionLocal() as db:
        pre_setlist = (
            await db.execute(select(PreSetlist).where(PreSetlist.concert_id == concert_id))
        ).scalar_one_or_none()
        return len(pre_setlist.songs) if pre_setlist is not None else 0


async def run(
    dry_run: bool, include_past: bool, limit: int | None, concert_id: str | None, delay: float, force: bool
) -> None:
    if not settings.PRE_SETLIST_MODEL_ENABLED:
        print("PRE_SETLIST_MODEL_ENABLED가 꺼져 있어서 중단함(켜져 있어야 모델 방식으로 생성됨)")
        return

    targets = await _targets(include_past, concert_id, force)
    if limit is not None:
        targets = targets[:limit]
    scope = "지난 공연 포함" if include_past else "끝나지 않은 공연만"
    kind = "예상 셋리" if force else "모델을 안 거친 예상 셋리"
    print(f"{kind} {len(targets)}개 ({scope})" + (" - dry-run" if dry_run else ""))
    if dry_run:
        for concert, pre_setlist in targets:
            sources = {s.get("source") or "setlistfm" for s in pre_setlist.songs}
            print(f"  {concert.start_date:%Y-%m-%d} {concert.name} | {len(pre_setlist.songs)}곡 ({'/'.join(sorted(sources))})")
        return

    counts: dict[str, int] = {}
    for i, (concert, pre_setlist) in enumerate(targets, 1):
        before = len(pre_setlist.songs)
        result = await _regenerate(concert.id, pre_setlist.songs)
        counts[result] = counts.get(result, 0) + 1
        after = await _song_count(concert.id)
        print(f"[{i}/{len(targets)}] {concert.name}: {result} ({before}곡 -> {after}곡)")
        await asyncio.sleep(delay)

    print("\n결과: " + ", ".join(f"{k} {v}" for k, v in counts.items()))
    if counts.get("실패(기존 유지)"):
        print("실패한 공연은 같은 명령을 다시 실행하면 그 공연들만 다시 대상이 됨")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="대상만 출력하고 아무것도 바꾸지 않음")
    parser.add_argument("--all", action="store_true", help="이미 끝난 공연도 포함")
    parser.add_argument("--force", action="store_true", help="이미 모델을 거친 것도 다시 생성(유저 수정본 제외)")
    parser.add_argument("--limit", type=int, help="앞에서부터 N개만")
    parser.add_argument("--concert-id", help="이 공연 하나만")
    parser.add_argument("--delay", type=float, default=_DELAY_SECONDS, help="공연 사이 대기 시간(초)")
    args = parser.parse_args()
    asyncio.run(run(args.dry_run, args.all, args.limit, args.concert_id, args.delay, args.force))


if __name__ == "__main__":
    main()
