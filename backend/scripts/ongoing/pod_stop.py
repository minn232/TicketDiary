"""[3/3단계] RunPod pod 정리 (GPU 과금 종료). 멱등이라 이미 없어도 무해.

새 방식(RUNPOD_TEMPLATE_ID 등 설정)이면 td-llm-batch 이름의 pod을 삭제하고 삭제 확인까지 함,
옛 방식이면 후보 pod을 정지. 이름이 다른 pod(LLM팀 수동 pod 등)은 건드리지 않음.

테스트 다 끝났다 싶으면 원할 때 바로 실행. 정기 안전망(KST 05·06·09·10시 정지, 03~04·07~08시
유휴 체크)을 기다릴 필요 없음.

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/ongoing/pod_stop.py
"""

import asyncio
import logging
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from app.services.runpod import stop_pod  # noqa: E402

logging.basicConfig(level=logging.INFO)


async def main() -> None:
    print("RunPod pod 정리(삭제/정지) 요청 중...")
    ok = await stop_pod()
    if ok:
        print("pod 정리 완료.")
    else:
        print("pod 정리 실패 (RUNPOD_API_KEY와 새 방식 설정 또는 옛 RUNPOD_POD_ID 확인, 위 [LLM] 로그 확인).")


if __name__ == "__main__":
    asyncio.run(main())
