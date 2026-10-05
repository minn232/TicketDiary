"""[2/3단계] SSH 접속 대기 + start_vllm.sh 원격 실행 + llm_server 준비될 때까지 대기.

pod은 이미 켜져 있다는 전제(pod_start.py를 먼저 돌렸거나 RunPod 콘솔에서 직접 켠 경우
둘 다 상관없음 - pod이 안 켜져 있으면 SSH 접속 대기 단계에서 타임아웃남).

start_vllm.sh는 tmux 세션 2개로 띄우므로, 진행 상황을 실시간으로 보거나 직접 개입하고
싶으면 이 스크립트 실행 중/후에 별도로 pod에 SSH로 들어가서 아래를 attach하면 됨(빠져나올
땐 Ctrl+b, d로 detach - 세션 자체는 계속 살아있음). pod에 tmux가 없으면 최초 1회
`apt-get install -y tmux` 필요.
  - `tmux attach -t llm_start` : 래퍼 스크립트 진행상황(vLLM/llm_server/tunnel 기동 단계)
  - `tmux attach -t vllm_log`  : vLLM 자체 실시간 로그(요청 처리, 생성 진행상황 등)

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/llm_start.py
"""

import asyncio
import logging
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from app.services.runpod import (  # noqa: E402
    _wait_for_ssh_ready,
    run_start_script_via_ssh,
    wait_until_llm_server_ready,
)

logging.basicConfig(level=logging.INFO)


async def main() -> None:
    print("SSH 접속 준비 대기 중... (pod이 아직 안 켜져 있으면 여기서 최대 3분 후 타임아웃)")
    if not await _wait_for_ssh_ready():
        print("SSH 접속이 준비되지 않았습니다. pod이 켜져 있는지(pod_start.py 먼저 실행했는지) 확인.")
        return

    print("start_vllm.sh 원격 실행 중 (vLLM+llm_server+cloudflared 기동, tmux 세션 'llm_start')...")
    if not await run_start_script_via_ssh():
        print("start_vllm.sh 원격 실행 요청 실패.")
        return
    print("  -> pod에 SSH로 들어가서 `tmux attach -t llm_start` 하면 실시간으로 보고 개입 가능")

    print("llm_server 준비 대기 중... (vLLM 모델 로딩 포함 최대 10분)")
    if await wait_until_llm_server_ready():
        print("llm_server 준비 완료. 이제 크롤링/아티스트 추출 전송을 돌려도 됨.")
    else:
        print("llm_server가 시간 안에 준비되지 않음. `tmux attach -t llm_start`로 들어가서 진행 상황 확인 필요.")


if __name__ == "__main__":
    asyncio.run(main())
