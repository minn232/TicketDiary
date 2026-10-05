"""[3/3단계] RunPod pod 정지 (GPU 과금 종료). 멱등이라 이미 꺼져 있어도 무해.

테스트 다 끝났다 싶으면 원할 때 바로 실행. 정기 stop 배치(KST 01~02시)를 기다릴
필요 없음.

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/pod_stop.py
"""

import asyncio
import logging
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from app.services.runpod import stop_pod  # noqa: E402

logging.basicConfig(level=logging.INFO)


async def main() -> None:
    print("RunPod pod 정지 요청 중...")
    ok = await stop_pod()
    if ok:
        print("pod 정지 요청 완료.")
    else:
        print("pod 정지 요청 실패 (RUNPOD_API_KEY/RUNPOD_POD_ID 설정 또는 로그 확인).")


if __name__ == "__main__":
    asyncio.run(main())
