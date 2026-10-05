"""[1/3단계] RunPod pod만 켠다 (SSH/vLLM/llm_server는 건드리지 않음).

GPU 자리가 날 때 일단 pod부터 잡아두고 싶을 때 이것만 먼저 실행.
SSH 접속 준비까지는 기다리지 않고 시작 요청만 보내고 바로 끝난다(멱등이라 이미
켜져 있어도 무해). vLLM/llm_server를 실제로 띄우려면 뒤이어 llm_start.py를 실행할 것.

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/pod_start.py
"""

import asyncio
import logging
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from app.services.runpod import start_pod  # noqa: E402

logging.basicConfig(level=logging.INFO)


async def main() -> None:
    print("RunPod pod 시작 요청 중...")
    ok = await start_pod()
    if ok:
        print("pod 시작 요청 완료. OS/SSH 부팅에 시간이 걸리니 곧바로 llm_start.py를 돌려도")
        print("내부에서 SSH 준비될 때까지 알아서 기다린다.")
    else:
        print("pod 시작 요청 실패 (RUNPOD_API_KEY/RUNPOD_POD_ID 설정 또는 로그 확인).")


if __name__ == "__main__":
    asyncio.run(main())
