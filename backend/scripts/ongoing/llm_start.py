"""[2/3단계] 새벽 배치(_run_llm_attempt)와 같은 기동 절차를 수동으로 한 번 실행.

start_pod_and_launch_services()를 그대로 부름. 서버 .env 설정에 따라 두 방식 중 하나로 동작
- 새 방식(RUNPOD_TEMPLATE_ID·RUNPOD_NETWORK_VOLUME_ID·RUNPOD_GPU_TYPE_IDS 모두 설정): td-llm-batch
  이름으로 pod을 새로 생성(후보 GPU를 순서대로 시도) → SSH 준비 대기 → start_vllm.sh 원격 실행 →
  llm_server 준비 대기. 같은 이름의 RUNNING pod이 있으면 새로 안 만들고 이어 씀(llm_server가 이미
  살아 있으면 start_vllm.sh도 다시 안 돌림). 기동 실패 시 pod을 삭제하고 새 pod으로 1회 재시도
- 옛 방식(새 설정이 비어 있을 때): 후보 pod(기본 → 보조)을 순서대로 resume → 같은 순서로 진행.
  켜졌는데 못 쓰게 된 pod은 그 자리에서 정지
- 스크립트 로그에 ERROR가 찍히면 1500초를 다 기다리지 않고 바로 실패 처리
- 성공하면 켜둔 채로 끝남 - 전송까지 마친 뒤 pod_stop.py로 끌 것(새 방식이면 pod 삭제)
- 정기 시각(KST 03·07시 시도, 05·06·09·10시 정지)과 겹치지 않게 돌릴 것 - 정기 정지가 이름이
  td-llm-batch인 pod을 지움

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

from app.services.runpod import (  # noqa: E402
    candidate_pod_ids,
    gpu_type_ids,
    new_pod_mode,
    start_pod_and_launch_services,
)

logging.basicConfig(level=logging.INFO)


async def main() -> None:
    if new_pod_mode():
        print(f"새 방식: td-llm-batch pod을 새로 생성(GPU 후보 {gpu_type_ids()} 순서대로) 후 기동 (SSH 최대 3분 + llm_server 최대 25분)")
    else:
        print(f"옛 방식: 후보 pod {candidate_pod_ids()} 순서대로 기동 시도 (pod당 SSH 최대 3분 + llm_server 최대 25분)")
    if await start_pod_and_launch_services():
        print("llm_server 준비 완료. 이제 크롤링/아티스트 추출 전송을 돌려도 됨. 끝나면 pod_stop.py로 정지.")
    else:
        print("기동 실패 - 새 방식이면 만든 pod은 삭제됨, 옛 방식이면 정지됨. 원인은 위 [LLM] 로그와 pod의 스크립트 로그 확인.")


if __name__ == "__main__":
    asyncio.run(main())
