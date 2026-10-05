"""자정 배치(_run_artist_extraction_send)를 기다리지 않고, 아티스트 정보 없는 공연들을
LLM팀 포스터 추출 파이프라인으로 즉시 1회 전송하는 일회용 스크립트.
(LLM팀과 시간 맞춰서 원할 때 한 번에 돌리고 싶을 때 사용)

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/send_artist_extraction_now.py            # 대상 전체 전송
    venv/bin/python3 scripts/send_artist_extraction_now.py --limit 30 # 소규모로 먼저 테스트

주의:
- RunPod pod이 꺼져있으면 이 스크립트가 깨우고(idempotent), llm_server 헬스체크가
  응답할 때까지 기다린 다음에 전송한다. 다만 실제 포스터 처리는 전송 후에도 llm_server
  쪽에서 백그라운드로 계속 진행되므로(대량이면 수십 분~수 시간), 이 스크립트가 끝났다고
  처리가 다 끝난 게 아니다.
- pod을 자동으로 끄지 않는다 - 전송 직후에 꺼버리면 처리 중인 작업이 통째로 날아간다.
  처리가 끝났다고 판단되면 직접 RunPod 콘솔에서 끄거나, 정해진 정기 stop 배치(KST 01~02시)를
  기다릴 것. 이 스크립트를 심야 시간대가 아닌 때 돌렸다면 정기 stop이 그날 안에 안 걸릴 수
  있으니 특히 주의.
"""

import argparse
import asyncio
import logging
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from sqlalchemy import func, select  # noqa: E402

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.concert import Concert  # noqa: E402
from app.services.crawler import artist_extraction_target_filter, send_posters_for_artist_extraction  # noqa: E402
from app.services.runpod import start_pod_and_launch_services, wait_until_llm_server_ready  # noqa: E402

logging.basicConfig(level=logging.INFO)


# send_posters_for_artist_extraction의 대상 조건과 동일하게 유지하려고 필터를 그쪽에서
# 그대로 가져다 씀(미리보기 카운트용) - 여기서 따로 조건을 베껴 적지 않음
def _target_query():
    return select(func.count()).select_from(Concert).where(
        Concert.genre.contains(["대중음악"]),
        func.cardinality(Concert.artist_name) < 4,
        Concert.poster_url.isnot(None),
        artist_extraction_target_filter(datetime.now(timezone.utc)),
    )


async def main(limit: int | None) -> None:
    async with AsyncSessionLocal() as db:
        target_count = await db.scalar(_target_query())
    print(f"아티스트 추출 대상 공연: {target_count}건" + (f" (이번엔 최대 {limit}건만 전송)" if limit else ""))
    if not target_count:
        print("전송할 대상이 없어 종료합니다.")
        return

    print("RunPod pod 기동 확인 중...")
    await start_pod_and_launch_services()
    print("llm_server 준비 대기 중... (모델 로딩 포함 최대 5분)")
    if not await wait_until_llm_server_ready():
        print("llm_server가 준비되지 않아 전송을 포기합니다. (LLM_ARTIST_URL/pod 상태 확인 필요)")
        return

    print("전송 시작...")
    sent = await send_posters_for_artist_extraction(limit=limit)
    print(f"전송 완료: {sent}건 (LLM 서버 쪽에서 백그라운드로 계속 처리됨, 이 스크립트는 여기서 끝)")
    print("처리가 끝났다고 판단되면 pod은 직접 꺼주세요 (자동으로 안 꺼짐).")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--limit", type=int, default=None, help="이번에 전송할 최대 건수 (기본: 전체)")
    args = parser.parse_args()
    asyncio.run(main(args.limit))
