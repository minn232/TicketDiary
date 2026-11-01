"""서버 크롤 배치 2개(crawl_retry/festival_lineup_check) 주석 해제 전 마지막 백필 - 1회용(2026-11-02).

해제하면 YES24/멜론 전용 공연은 KOPIS 스크린샷으로만 찍혀 예매일/배송일/시간표를 못 얻고, 정기
경로는 전부 end_date > now + 검수 공연 제외라 아래 공연들은 영영 안 감. 그래서 한 번에 모아 보냄
  1) YES24/멜론만 있는(인터파크 링크 없음) 앞으로의 공연 전부
  2) 티켓이 등록된 지난 공연 전부(시간표용)
  3) 앞으로의 공연 중 예전에 LLM 결과를 받은 것 - 11/2에 옛 시간표를 전부 지워서 다시 받아야 함
검수된 공연도 보냄 - /crawl-result 콜백이 검수 공연은 artist_name을 안 건드리고 lineup도 검수된
아티스트 출연일만 받음(crawl.py).

스크린샷은 _BACKFILL_SINCE 이후에 찍힌 것(URL의 시각 키 기준)만 "새것"으로 보고, 새것이 아닌
대상만 찍음 - 중간에 끊겨도 같은 명령을 다시 돌리면 이어서 진행됨.
9~10월에 로컬로 찍어둔 YES24/멜론 스크린샷이 있으면 다시 찍지 않고 새 키로 복사만 함(--reuse-local) -
같은 URL은 pod dedup에 걸려 재분석이 안 돼서 새 URL이 필요함.

순서 (서버, tmux 안에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/ongoing/send_backfill_to_llm_once.py --dry-run
    # YES24/멜론은 서버 IP가 막혀 있어 로컬에서 찍음 - 예전 로컬 스크린샷 없는 대상만 파일로 뽑아 가져감
    # (--refresh-days N이면 N일 안에 열리는 공연은 예전 스크린샷이 있어도 다시 찍음)
    venv/bin/python3 scripts/ongoing/send_backfill_to_llm_once.py --export-local /tmp/backfill_local.json
    #   (로컬) scp td-server:/tmp/backfill_local.json .
    #   (로컬) python scripts/yes24_melon_local_crawl.py --targets-file backfill_local.json --limit 40
    # 로컬 크롤이 끝난 뒤에 복사 - 먼저 하면 복사본이 새것으로 잡혀 --refresh-days 대상에서 빠짐
    venv/bin/python3 scripts/ongoing/send_backfill_to_llm_once.py --reuse-local
    venv/bin/python3 scripts/ongoing/send_backfill_to_llm_once.py --crawl-server   # 인터파크/KOPIS 대상
    venv/bin/python3 scripts/ongoing/send_backfill_to_llm_once.py --send           # pod 켜고 전송, 지켜봄

주의: CRAWL 동시성 1이라 LLM이 약 1건/분 - 200건대면 4시간 안팎. 정지 안전망(KST 05/06/09/10시)에
안 걸리게 KST 10시 이후에 --send 할 것. 서버 RAM이 작아 서버 크롤은 한 번에 하나씩(건당 최대 150초)
"""

import argparse
import asyncio
import json
import re
import sys
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

import httpx  # noqa: E402
from sqlalchemy import or_, select  # noqa: E402

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.concert import Concert  # noqa: E402
from app.models.ticket import Ticket  # noqa: E402
from app.services.crawler import (  # noqa: E402
    _crawl_first_success,
    _pick_crawl_candidates,
    _upload_screenshot,
    crawl_kopis,
)
from app.services.runpod import start_pod_and_launch_services, stop_pod, wait_until_llm_server_ready  # noqa: E402
from app.services.timetable_ranges import compute_timetable_ranges  # noqa: E402
from scripts.ongoing.run_llm_crawl_batch import _count_done, _send_targets  # noqa: E402

# LLM 시간표 로직이 완성된 날(KST 11/2 0시) - 이전 스크린샷은 이미 분석됐거나 오래돼서 새로 찍음
_BACKFILL_SINCE = datetime(2026, 11, 1, 15, 0, tzinfo=timezone.utc)

# crawl_and_save의 _CRAWL_TIMEOUT과 같은 값
_CRAWL_TIMEOUT = 150

_LOCAL_SITES = ("YES24", "MELON", "MELONTICKET")
_URL_TS_RE = re.compile(r"_(\d{10})\.png$")
# 로컬 크롤 스크립트가 올린 키(save_manual_crawl_screenshot) - "yes24_1757..." / "melon_1757..."
_LOCAL_SHOT_RE = re.compile(r"/(yes24|melon|melonticket)_\d{10}\.png$")


def _route(concert: Concert) -> str:
    links = concert.ticketing_links or {}
    if "INTERPARK" in links:
        return "interpark"
    if any(site in links for site in _LOCAL_SITES):
        return "local"
    return "kopis"


def _group(concert: Concert, now: datetime) -> str:
    if concert.end_date is not None and concert.end_date <= now:
        return "지난 공연(티켓 있음)"
    if _route(concert) == "local":
        return "YES24/멜론 앞으로 공연"
    return "예전 LLM 결과 다시 받기"


# 고정 키(crawl_and_save의 "interpark.png" 등)는 언제 찍혔는지 몰라 새것으로 안 봄
def _is_fresh(concert: Concert) -> bool:
    match = _URL_TS_RE.search(concert.crawl_screenshot_url or "")
    return bool(match) and datetime.fromtimestamp(int(match.group(1)), tz=timezone.utc) >= _BACKFILL_SINCE


async def _load_targets() -> list[Concert]:
    now = datetime.now(timezone.utc)
    ticketed = select(Ticket.concert_id).where(Ticket.concert_id.isnot(None))
    yes24_melon_only = (
        ~Concert.ticketing_links.has_key("INTERPARK")
        & or_(*(Concert.ticketing_links.has_key(site) for site in _LOCAL_SITES))
    )
    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(Concert)
            .where(
                or_(
                    (Concert.end_date > now) & yes24_melon_only,
                    (Concert.end_date <= now) & Concert.id.in_(ticketed),
                    (Concert.end_date > now) & Concert.crawl_result_received_at.isnot(None),
                )
            )
            .order_by(Concert.start_date)
        )
        return list(result.scalars().all())


def _print_summary(targets: list[Concert]) -> None:
    now = datetime.now(timezone.utc)
    print(f"대상 {len(targets)}건")
    for (group, route), count in sorted(Counter((_group(c, now), _route(c)) for c in targets).items()):
        fresh = sum(1 for c in targets if _group(c, now) == group and _route(c) == route and _is_fresh(c))
        print(f"  {group} / {route}: {count}건 (새 스크린샷 {fresh})")
    local = [c for c in targets if _route(c) == "local" and not _is_fresh(c)]
    reusable = sum(1 for c in local if _has_local_shot(c))
    print(f"  로컬 대상 중 예전 스크린샷 복사 {reusable}건 / 새로 찍을 것 {len(local) - reusable}건")
    reviewed = sum(1 for c in targets if c.admin_reviewed_at or c.ai_reviewed_at)
    print(f"  그중 검수된 공연 {reviewed}건 - 콜백이 아티스트는 안 건드림")


def _has_local_shot(concert: Concert) -> bool:
    return bool(_LOCAL_SHOT_RE.search(concert.crawl_screenshot_url or ""))


# 예전에 로컬로 찍은 실제 예매처 스크린샷을 새 시각 키로 복사 - 다시 찍는 대신 재분석만 받음
async def _reuse_local(targets: list[Concert]) -> None:
    to_copy = [c for c in targets if _route(c) == "local" and _has_local_shot(c) and not _is_fresh(c)]
    print(f"예전 로컬 스크린샷 복사 대상 {len(to_copy)}건")
    failed: list[str] = []
    async with httpx.AsyncClient(timeout=60.0) as client:
        for i, target in enumerate(to_copy, 1):
            try:
                response = await client.get(target.crawl_screenshot_url)
                response.raise_for_status()
            except httpx.HTTPError as e:
                print(f"  [{i}/{len(to_copy)}] {target.name} - 다운로드 실패: {e}")
                failed.append(target.name)
                continue
            site = _LOCAL_SHOT_RE.search(target.crawl_screenshot_url).group(1)
            url = await _upload_screenshot(
                response.content, target.id, f"{site}_{int(datetime.now(timezone.utc).timestamp())}"
            )
            if not url:
                failed.append(target.name)
                continue
            async with AsyncSessionLocal() as db:
                concert = await db.get(Concert, target.id)
                concert.crawl_screenshot_url = url
                if concert.timetable_ranges is None:
                    concert.timetable_ranges = await compute_timetable_ranges(response.content)
                concert.crawl_result_received_at = None
                await db.commit()
            print(f"  [{i}/{len(to_copy)}] {target.name} -> {url}")
    if failed:
        print(f"복사 실패 {len(failed)}건(--export-local에 남음): {failed}")


def _export_local(targets: list[Concert], path: str, refresh_days: int) -> None:
    now = datetime.now(timezone.utc)
    items = []
    for c in targets:
        if _route(c) != "local" or _is_fresh(c):
            continue
        # 예전 로컬 스크린샷은 --reuse-local로 복사하므로 제외. 단 곧 열리는 공연은 시간표/배송
        # 안내가 그 뒤에 올라왔을 수 있어 --refresh-days 안이면 다시 찍음
        imminent = c.start_date is not None and (c.start_date - now).days < refresh_days
        if _has_local_shot(c) and not imminent:
            continue
        links = c.ticketing_links or {}
        items.append(
            {
                "concert_id": str(c.id),
                "kopis_id": c.kopis_id,
                "name": c.name,
                "candidates": [{"site": site, "url": links[site]} for site in _LOCAL_SITES if site in links],
            }
        )
    Path(path).write_text(json.dumps({"items": items}, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"로컬 크롤 대상 {len(items)}건 → {path}")


async def _capture(concert: Concert) -> tuple[str | None, bytes | None]:
    if _route(concert) == "interpark":
        site_key, image_bytes = await _crawl_first_success(concert, _pick_crawl_candidates(None, concert.ticketing_links))
        if image_bytes is not None:
            return site_key.lower(), image_bytes
    return "kopis", await crawl_kopis(concert)


# send_unreviewed_to_llm_once.py의 _crawl_one과 같음 - 시각 붙인 키로 올리고 받은 표시를 비움
async def _crawl_one(concert_id) -> bool:
    async with AsyncSessionLocal() as db:
        concert = await db.get(Concert, concert_id)
        try:
            site, image_bytes = await asyncio.wait_for(_capture(concert), timeout=_CRAWL_TIMEOUT)
        except asyncio.TimeoutError:
            print(f"    타임아웃({_CRAWL_TIMEOUT}초)")
            return False
        if image_bytes is None:
            return False

        upload_key = f"{site}_{int(datetime.now(timezone.utc).timestamp())}"
        url = await _upload_screenshot(image_bytes, concert.id, upload_key)
        if not url:
            return False
        concert.crawl_screenshot_url = url
        concert.timetable_ranges = await compute_timetable_ranges(image_bytes)
        concert.crawl_result_received_at = None
        concert.crawl_attempted_at = datetime.now(timezone.utc)
        concert.crawl_attempt_count += 1
        await db.commit()
        print(f"    -> {site}: {url}")
        return True


async def _crawl_server(targets: list[Concert]) -> None:
    to_crawl = [c for c in targets if _route(c) != "local" and not _is_fresh(c)]
    print(f"서버에서 찍을 대상 {len(to_crawl)}건")
    failed: list[str] = []
    for i, concert in enumerate(to_crawl, 1):
        print(f"  [{i}/{len(to_crawl)}] {concert.name}")
        if not await _crawl_one(concert.id):
            failed.append(concert.name)
    if failed:
        print(f"스크린샷 확보 실패 {len(failed)}건(전송에서 빠짐, 시간표는 관리자 화면으로): {failed}")


async def _send(targets: list[Concert], watch_minutes: float, poll_interval: float, skip_pod_start: bool) -> None:
    send_targets = [
        {
            "id": c.id,
            "name": c.name,
            "screenshot_url": c.crawl_screenshot_url,
            "timetable_ranges": c.timetable_ranges,
        }
        for c in targets
        if _is_fresh(c) and c.crawl_result_received_at is None
    ]
    not_fresh = sum(1 for c in targets if not _is_fresh(c))
    print(f"전송 대상 {len(send_targets)}건 (새 스크린샷 없는 {not_fresh}건은 빠짐)")
    if not send_targets:
        return

    if skip_pod_start:
        print("--skip-pod-start: pod 시작 단계 건너뜀")
    elif await wait_until_llm_server_ready(timeout_seconds=5, interval_seconds=5):
        print("LLM 서버 이미 켜져있음, pod 시작 단계 건너뜀")
    else:
        print("RunPod 시작 중...")
        print(f"  -> {'성공' if await start_pod_and_launch_services() else '실패 또는 미설정'}")
    print("llm_server 준비 대기 중(최대 10분)...")
    if not await wait_until_llm_server_ready():
        print("llm_server가 준비되지 않음 - 중단(다시 돌리면 그대로 이어서 전송됨)")
        return

    if not await _send_targets(send_targets):
        return
    print("전송 완료. 처리되는 대로 /crawl-result 웹훅으로 자동 반영됨")

    ids = [t["id"] for t in send_targets]
    deadline = time.monotonic() + watch_minutes * 60
    while time.monotonic() < deadline:
        done = await _count_done(ids)
        print(f"  [{time.strftime('%H:%M:%S')}] LLM 콜백 수신: {done}/{len(ids)}건")
        if done == len(ids):
            print("전부 반영됨. pod 정지 중...")
            print("  -> pod 정지 성공" if await stop_pod() else "  -> pod 정지 실패(로그 확인 필요)")
            return
        await asyncio.sleep(poll_interval)
    print(f"지켜보기 시간 종료. 최종 {await _count_done(ids)}/{len(ids)}건 반영 - pod 종료는 직접 판단할 것")


async def main(args: argparse.Namespace) -> None:
    targets = await _load_targets()
    _print_summary(targets)
    if args.reuse_local:
        await _reuse_local(targets)
    elif args.export_local:
        _export_local(targets, args.export_local, args.refresh_days)
    elif args.crawl_server:
        await _crawl_server(targets)
    elif args.send:
        await _send(targets, args.watch_minutes, args.poll_interval, args.skip_pod_start)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="대상 건수만 출력(기본 동작)")
    mode.add_argument("--reuse-local", action="store_true", help="예전 로컬 YES24/멜론 스크린샷을 새 키로 복사")
    mode.add_argument("--export-local", metavar="PATH", help="YES24/멜론 로컬 크롤 대상을 JSON 파일로 저장")
    mode.add_argument("--crawl-server", action="store_true", help="인터파크/KOPIS 대상을 서버에서 찍음")
    mode.add_argument("--send", action="store_true", help="새 스크린샷 대상을 LLM으로 전송하고 지켜봄")
    parser.add_argument(
        "--refresh-days", type=int, default=0,
        help="--export-local에서 이 일수 안에 열리는 공연은 예전 로컬 스크린샷이 있어도 다시 찍음(기본 0=안 함)",
    )
    parser.add_argument("--watch-minutes", type=float, default=360.0, help="반영 현황을 지켜볼 시간(분), 기본 6시간")
    parser.add_argument("--poll-interval", type=float, default=60.0, help="현황 확인 간격(초), 기본 60초")
    parser.add_argument("--skip-pod-start", action="store_true", help="pod이 이미 켜져있으면 시작 단계 건너뜀")
    asyncio.run(main(parser.parse_args()))
