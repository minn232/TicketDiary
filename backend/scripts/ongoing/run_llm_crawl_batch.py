"""2026-09-15(월) 22시경 LLM 연동 시점에 실행할 일회성 스크립트 - RunPod을 켜고, 지금까지
모아둔 크롤링 스크린샷(YES24/멜론 로컬 크롤링 결과 포함, crawl_screenshot_url이 있는 콘서트
전부)을 LLM팀 서버로 보낸다.

완료 판정은 ticketing_date가 아니라 Concert.crawl_result_received_at(콜백이 실제로 도착한
시각, 개별 필드 유무와 무관하게 항상 찍힘)으로 한다 - ticketing_date만 보면 스크린샷에서
날짜를 못 찾은 건(페스티벌 등)을 영원히 미완료로 오판한다(2026-09-16 실측: pod dedup 11건
vs ticketing_date 3건). 전송 대상도 같은 필드로 걸러서, 이미 콜백 받은 건(ticketing_date가
비어도)은 재전송하지 않는다 - 그래서 send_screenshots_to_llm을 그대로 쓰지 않고 이 스크립트가
직접 대상을 걸러 전송한다(그 함수는 crawl_result_received_at 조건이 없어 이미 처리한 것도
다시 보냄).

결과는 LLM 서버가 각 건 처리를 마치는 대로 기존 /crawl-result 웹훅으로 자동 반영되므로
이 스크립트가 직접 받아오는 게 아니라, 그 반영 진행 상황만 주기적으로 출력해서 지켜볼 수
있게 해준다.

전송 대상이 전부 반영되면(또는 애초에 대상이 없으면) 이 스크립트가 직접 pod을 정지시킨다
(이 배치는 llm_night_batch_state로 추적되는 정기 야간배치가 아니라서 기존 조기정지 로직이
못 잡음). 지켜보기 시간(--watch-minutes) 안에 다 못 끝나면 정지시키지 않고 그대로 둠 -
그 경우엔 계속 처리 중일 수 있으니 pod_stop.py로 직접 판단해서 정지할 것.

재실행해도 안전함 - llm_server 쪽에 (concert_id, screenshot_url) 단위 dedup도 있고, 이
스크립트 자체도 crawl_result_received_at이 이미 찍힌 건은 대상에서 빼고 보낸다.

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/ongoing/run_llm_crawl_batch.py
    venv/bin/python3 scripts/ongoing/run_llm_crawl_batch.py --watch-minutes 30   # 지켜볼 시간(기본 20분)
    venv/bin/python3 scripts/ongoing/run_llm_crawl_batch.py --skip-pod-start    # pod이 이미 켜져있을 때
"""

import argparse
import asyncio
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

import httpx  # noqa: E402
from sqlalchemy import select  # noqa: E402

from app.core.config import settings  # noqa: E402
from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.concert import Concert  # noqa: E402
from app.services.llm_batch_state import mark_llm_sent  # noqa: E402
from app.services.runpod import (  # noqa: E402
    start_pod_and_launch_services,
    stop_pod,
    wait_until_llm_server_ready,
)


# send_screenshots_to_llm과 대상 조건이 다르다(crawl_result_received_at IS NULL 추가) - 이미
# 콜백 받은 건 재전송 안 하려는 목적이라 그 함수를 그대로 못 쓰고 여기서 직접 조회+전송한다
async def _snapshot_targets() -> list[dict]:
    now = datetime.now(timezone.utc)
    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(Concert).where(
                Concert.crawl_screenshot_url.isnot(None),
                Concert.end_date > now,
                Concert.admin_reviewed_at.is_(None),
                Concert.ai_reviewed_at.is_(None),
                Concert.crawl_result_received_at.is_(None),
            )
        )
        concerts = result.scalars().all()
    return [
        {
            "id": c.id,
            "name": c.name,
            "kopis_id": c.kopis_id,
            "screenshot_url": c.crawl_screenshot_url,
            "timetable_ranges": c.timetable_ranges,
        }
        for c in concerts
    ]


async def _send_targets(targets: list[dict]) -> bool:
    if not settings.LLM_CRAWL_URL:
        print("LLM_CRAWL_URL 미설정, 전송 건너뜀")
        return False
    payload = [
        {
            "concert_id": str(t["id"]),
            "concert_name": t["name"],
            "screenshot_url": t["screenshot_url"],
            "timetable_ranges": t["timetable_ranges"],
        }
        for t in targets
    ]
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(
                settings.LLM_CRAWL_URL,
                json=payload,
                headers={"Authorization": f"Bearer {settings.LLM_EXTRACT_API_KEY}"},
            )
            response.raise_for_status()
        await mark_llm_sent(len(targets))
        return True
    except Exception as e:
        print(f"전송 실패: {e}")
        return False


async def _count_done(ids: list) -> int:
    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(Concert.id).where(Concert.id.in_(ids), Concert.crawl_result_received_at.isnot(None))
        )
        return len(result.scalars().all())


async def main(watch_minutes: float, poll_interval: float, skip_pod_start: bool) -> None:
    if skip_pod_start:
        print("--skip-pod-start: pod 시작 단계 건너뜀(이미 켜져있다고 가정)")
    else:
        # start_pod_and_launch_services()는 무조건 start_vllm.sh를 SSH로 재실행하는데,
        # llm이 이미 떠있는 상태에서 이걸 부르면 기존 tmux 세션을 죽이고 다시 띄우게 돼서
        # 불필요한 재기동/방해가 될 수 있음 - 먼저 짧게 헬스체크해서 이미 켜져있으면 건너뜀
        print("LLM 서버 상태 확인 중...")
        already_up = await wait_until_llm_server_ready(timeout_seconds=5, interval_seconds=5)
        if already_up:
            print("  -> 이미 켜져있음, pod 시작 단계 건너뜀")
        else:
            print("RunPod 시작 중...")
            started = await start_pod_and_launch_services()
            print(f"  -> {'성공' if started else '실패 또는 미설정'}")

    print("llm_server 준비 대기 중(최대 10분)...")
    ready = await wait_until_llm_server_ready()
    if not ready:
        print("llm_server가 준비되지 않음 - 중단. RUNPOD_API_KEY/POD_ID/LLM_CRAWL_URL 설정을 확인할 것.")
        return
    print("  -> 준비됨")

    targets = await _snapshot_targets()
    print(f"\n전송 대상 {len(targets)}건 (crawl_screenshot_url 있음 + 검수 안 됨 + 진행예정 + 콜백 미수신)")

    if not targets:
        print("\n대상이 없어서(전부 이미 콜백 받았거나 애초에 없음) 지켜볼 것도 없음. pod 정지 중...")
        print("  -> pod 정지 성공" if await stop_pod() else "  -> pod 정지 실패(로그 확인 필요)")
        return

    print("스크린샷 전송 중...")
    sent = await _send_targets(targets)
    print("  -> 전송 완료. LLM 서버가 비동기로 처리하며, 처리되는 대로 /crawl-result 웹훅으로 자동 반영됨."
          if sent else "  -> 전송 실패, 중단.")
    if not sent:
        return

    ids = [t["id"] for t in targets]
    print(f"\n{watch_minutes:.0f}분 동안 {poll_interval:.0f}초 간격으로 반영 현황을 지켜봄 "
          f"(Ctrl+C로 중단 가능, 전부 반영되면 자동으로 pod 정지)")
    deadline = time.monotonic() + watch_minutes * 60
    while time.monotonic() < deadline:
        done = await _count_done(ids)
        print(f"  [{time.strftime('%H:%M:%S')}] LLM 콜백 수신: {done}/{len(ids)}건")
        if done == len(ids):
            print("전부 반영됨. pod 정지 중...")
            print("  -> pod 정지 성공" if await stop_pod() else "  -> pod 정지 실패(로그 확인 필요)")
            return
        await asyncio.sleep(poll_interval)

    done = await _count_done(ids)
    print(f"\n지켜보기 시간 종료. 최종: {done}/{len(ids)}건 반영됨.")
    print("나머지는 LLM 서버가 계속 처리 중일 수 있음 - 이 스크립트를 또 돌리면(재실행해도 무해함)")
    print("이미 콜백 받은 건은 자동으로 제외하고 나머지만 다시 보냄. pod 종료는 직접 판단해서 진행할 것.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--watch-minutes", type=float, default=20.0, help="반영 현황을 지켜볼 시간(분), 기본 20분")
    parser.add_argument("--poll-interval", type=float, default=30.0, help="현황 확인 간격(초), 기본 30초")
    parser.add_argument("--skip-pod-start", action="store_true", help="pod이 이미 켜져있으면 시작 단계 건너뜀")
    args = parser.parse_args()
    asyncio.run(main(args.watch_minutes, args.poll_interval, args.skip_pod_start))
