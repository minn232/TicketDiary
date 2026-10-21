"""검수 안 된 공연(admin_reviewed_at/ai_reviewed_at 둘 다 NULL) 전부를 이미 끝난 공연까지 포함해서
크롤링 스크린샷 LLM 파이프라인으로 1회 보내는 일회용 스크립트(2026-10-21, 검수 안 됨 104건을 전부
페스티벌로 지정한 뒤 작성).

정기 경로(crawl_and_save/_check_festival_lineup/send_screenshots_to_llm)는 전부 end_date > now
조건이 걸려 있어 이미 끝난 공연은 크롤링도 전송도 안 됨 - 그 조건 없이 직접 처리한다.

1) 스크린샷이 없는 대상은 먼저 찍는다 - 인터파크 링크가 있으면 시도, 실패하거나 후보가 없으면
   KOPIS 상세페이지로 폴백(끝난 공연은 예매 페이지가 내려간 경우가 많음). 업로드 키는
   save_manual_crawl_screenshot처럼 매번 시각을 붙여 기존 이력을 안 덮어씀
2) pod을 켜고 llm_server 준비를 기다린 뒤 전송, 콜백 반영 현황을 지켜봄(run_llm_crawl_batch.py 재사용)

이미 LLM 콜백을 받은 공연(crawl_result_received_at 있음)은 기본으로 제외 - 같은 스크린샷 URL은
pod 쪽 (concert_id, screenshot_url) dedup에 걸려 재분석이 안 되기 때문. --include-received를 주면
그 공연들도 새로 찍어서(새 URL) 다시 보낸다.

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/ongoing/send_unreviewed_to_llm_once.py --dry-run       # 대상 건수만 확인
    venv/bin/python3 scripts/ongoing/send_unreviewed_to_llm_once.py
    venv/bin/python3 scripts/ongoing/send_unreviewed_to_llm_once.py --include-received
    venv/bin/python3 scripts/ongoing/send_unreviewed_to_llm_once.py --skip-pod-start  # pod이 이미 켜져있을 때

주의: 서버 RAM이 작아 브라우저는 한 번에 하나씩만 띄움(건당 최대 150초). 서버 SSH가 끊겨도
계속 돌도록 tmux 안에서 실행할 것.
"""

import argparse
import asyncio
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from sqlalchemy import select  # noqa: E402

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.concert import Concert  # noqa: E402
from app.services.crawler import (  # noqa: E402
    _crawl_first_success,
    _pick_crawl_candidates,
    _upload_screenshot,
    crawl_kopis,
)
from app.services.runpod import start_pod_and_launch_services, stop_pod, wait_until_llm_server_ready  # noqa: E402
from app.services.timetable_ranges import compute_timetable_ranges  # noqa: E402
from scripts.ongoing.run_llm_crawl_batch import _count_done, _send_targets  # noqa: E402

# crawl_and_save의 _CRAWL_TIMEOUT과 같은 값
_CRAWL_TIMEOUT = 150


async def _load_targets(include_received: bool) -> list[Concert]:
    async with AsyncSessionLocal() as db:
        query = select(Concert).where(Concert.admin_reviewed_at.is_(None), Concert.ai_reviewed_at.is_(None))
        if not include_received:
            query = query.where(Concert.crawl_result_received_at.is_(None))
        result = await db.execute(query.order_by(Concert.end_date))
        return list(result.scalars().all())


async def _capture(concert: Concert) -> tuple[str | None, bytes | None]:
    candidates = _pick_crawl_candidates(None, concert.ticketing_links)
    if candidates:
        site_key, image_bytes = await _crawl_first_success(concert, candidates)
        if image_bytes is not None:
            return site_key.lower(), image_bytes
    return "kopis", await crawl_kopis(concert)


# 한 건 찍어서 업로드 후 crawl_and_save가 성공했을 때와 같은 상태로 맞춤. 새 스크린샷이라
# crawl_result_received_at도 비움(안 비우면 콜백 반영 현황 집계가 처음부터 "완료"로 셈)
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


async def main(include_received: bool, dry_run: bool, watch_minutes: float, poll_interval: float,
               skip_pod_start: bool) -> None:
    targets = await _load_targets(include_received)
    now = datetime.now(timezone.utc)
    # --include-received면 이미 처리된 건은 스크린샷이 있어도 새로 찍어야 pod dedup을 피함
    to_crawl = [c for c in targets if c.crawl_screenshot_url is None or c.crawl_result_received_at is not None]
    ended = sum(1 for c in targets if c.end_date is not None and c.end_date <= now)
    print(f"대상 {len(targets)}건 (이미 끝난 공연 {ended}건 포함), 그중 새로 찍을 것 {len(to_crawl)}건")
    if dry_run or not targets:
        return

    failed: list[str] = []
    for i, concert in enumerate(to_crawl, 1):
        print(f"  [{i}/{len(to_crawl)}] {concert.name}")
        if not await _crawl_one(concert.id):
            failed.append(concert.name)
    if failed:
        print(f"스크린샷 확보 실패 {len(failed)}건(전송에서 빠짐): {failed}")

    if skip_pod_start:
        print("--skip-pod-start: pod 시작 단계 건너뜀")
    elif await wait_until_llm_server_ready(timeout_seconds=5, interval_seconds=5):
        print("LLM 서버 이미 켜져있음, pod 시작 단계 건너뜀")
    else:
        print("RunPod 시작 중...")
        print(f"  -> {'성공' if await start_pod_and_launch_services() else '실패 또는 미설정'}")
    print("llm_server 준비 대기 중(최대 10분)...")
    if not await wait_until_llm_server_ready():
        print("llm_server가 준비되지 않음 - 중단(찍어둔 스크린샷은 남아있어 다시 돌리면 이어서 전송됨)")
        return

    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(Concert).where(
                Concert.id.in_([c.id for c in targets]),
                Concert.crawl_screenshot_url.isnot(None),
                Concert.crawl_result_received_at.is_(None),
            )
        )
        send_targets = [
            {
                "id": c.id,
                "name": c.name,
                "screenshot_url": c.crawl_screenshot_url,
                "timetable_ranges": c.timetable_ranges,
            }
            for c in result.scalars().all()
        ]
    print(f"전송 대상 {len(send_targets)}건")
    if not send_targets or not await _send_targets(send_targets):
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


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--include-received", action="store_true", help="이미 LLM 콜백 받은 공연도 새로 찍어 다시 보냄")
    parser.add_argument("--dry-run", action="store_true", help="대상 건수만 출력하고 종료")
    parser.add_argument("--watch-minutes", type=float, default=30.0, help="반영 현황을 지켜볼 시간(분), 기본 30분")
    parser.add_argument("--poll-interval", type=float, default=30.0, help="현황 확인 간격(초), 기본 30초")
    parser.add_argument("--skip-pod-start", action="store_true", help="pod이 이미 켜져있으면 시작 단계 건너뜀")
    args = parser.parse_args()
    asyncio.run(main(args.include_received, args.dry_run, args.watch_minutes, args.poll_interval, args.skip_pod_start))
