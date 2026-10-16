"""[2/3단계] 새벽 배치(_run_llm_attempt)와 같은 기동 절차를 수동으로 한 번 실행.

start_pod_and_launch_services()를 그대로 부름 - 후보 pod(기본 → 보조) 순서대로
시작 요청 → SSH 준비 대기 → start_vllm.sh 원격 실행 → llm_server 준비 대기.
- 시작 요청은 멱등이라 pod_start.py나 RunPod 콘솔로 이미 켜둔 pod이어도 상관없음
- 스크립트 로그에 ERROR가 찍히면 1500초를 다 기다리지 않고 바로 다음 후보로 넘어감
- 켜졌는데 못 쓰게 된 pod은 그 자리에서 정지함(과금 방지). 성공하면 켜둔 채로 끝남 -
  전송까지 마친 뒤 pod_stop.py로 끌 것

스크립트 출력은 pod의 /workspace/start_vllm_remote_<pod>_<UTC시각>.log에 남고(경로는
"원격 실행 요청 완료" 줄에 찍힘), 실시간으로 보려면 pod에 SSH로 들어가서 attach(빠져나올
땐 Ctrl+b, d - 세션은 계속 살아있음).
  - `tmux attach -t llm_start` : 래퍼 스크립트 진행상황(vLLM/llm_server/tunnel 기동 단계)
  - `tmux attach -t vllm_log`  : vLLM 자체 실시간 로그(요청 처리, 생성 진행상황 등)

최대 30분 넘게 걸릴 수 있어서 서버 SSH가 끊기면 이 스크립트도 같이 죽음(그러면 정지
처리도 못 함) - tmux 안에서 돌릴 것(10/16 핫스팟 IP 변경으로 끊긴 적 있음).

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    tmux new -s llm_manual
    venv/bin/python3 scripts/ongoing/llm_start.py
"""

import asyncio
import logging
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from app.services.runpod import candidate_pod_ids, start_pod_and_launch_services  # noqa: E402

logging.basicConfig(level=logging.INFO)


async def main() -> None:
    print(f"후보 pod {candidate_pod_ids()} 순서대로 기동 시도 (pod당 SSH 최대 3분 + llm_server 최대 25분)")
    if await start_pod_and_launch_services():
        print("llm_server 준비 완료. 이제 크롤링/아티스트 추출 전송을 돌려도 됨. 끝나면 pod_stop.py로 정지.")
    else:
        print("모든 후보 pod 기동 실패 - 실패한 pod은 정지됨. 원인은 위 [LLM] 로그와 pod의 스크립트 로그 확인.")


if __name__ == "__main__":
    asyncio.run(main())
