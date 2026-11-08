"""[1회용 점검] 새 pod을 잠깐 만들어 /workspace의 LLM팀 스크립트·코드를 읽기만 하고 바로 삭제.

start_vllm.sh를 실행하지 않으므로 vLLM·터널·볼륨 파일을 건드리지 않음(마커 파일도 안 씀). 이름을
td-llm-probe로 만들어 안전망 정지(td-llm-batch 이름만 삭제)에 안 걸림. 설정은 서버 .env의
RUNPOD_TEMPLATE_ID·RUNPOD_NETWORK_VOLUME_ID·RUNPOD_GPU_TYPE_IDS를 그대로 씀. 끝나면(예외·Ctrl+C 포함) 삭제.

점검 항목: HF 캐시 위치(setup_local.sh·start_vllm.sh의 HF_HOME·/opt/models), vLLM 기동의 nohup/disown,
/workspace 밖 경로·pod ID 의존, vLLM 인자(gpu-memory-utilization 등), 동시성 설정
토큰·키 값은 출력에서 가림

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    PYTHONPATH=. venv/bin/python3 scripts/old/pod_inspect_once.py
"""

import asyncio
import re
import sys
import time

import httpx

from app.core.config import settings
from app.services import runpod

NAME = "td-llm-probe"

_MASK = re.compile(r"(eyJ[A-Za-z0-9_\-=.]{20,}|(?i:token|key|secret|password)\s*=\s*\S+)")


def _show(title: str, lines: list[str], limit: int = 60) -> None:
    print(f"\n=== {title}")
    if not lines:
        print("  (없음)")
    for line in lines[:limit]:
        print("  " + _MASK.sub("***", line)[:200])
    if len(lines) > limit:
        print(f"  ... 외 {len(lines) - limit}줄")


async def _cat(conn, path: str) -> list[str]:
    r = await conn.run(f"cat {path} 2>&1", check=False)
    return str(r.stdout or "").splitlines()


def _grep(lines: list[str], pattern: str) -> list[str]:
    rx = re.compile(pattern)
    return [f"{i}: {line.strip()}" for i, line in enumerate(lines, start=1) if rx.search(line)]


async def _inspect(pod_id: str) -> None:
    async with await runpod._ssh_connect(pod_id, connect_timeout=15) as conn:
        r = await conn.run("ls -la /workspace | head -40; echo ---; ls -la /workspace/huggingface 2>&1 | head -8; echo ---; echo HF_HOME=$HF_HOME", check=False)
        _show("/workspace 목록 (숨김 포함) / huggingface / HF_HOME", str(r.stdout or "").splitlines(), 60)

        setup = await _cat(conn, "/workspace/setup_local.sh")
        start = await _cat(conn, "/workspace/start_vllm.sh")
        print(f"\n(setup_local.sh {len(setup)}줄 / start_vllm.sh {len(start)}줄)")

        _show("[4] setup_local.sh - 모델·캐시·설치 관련", _grep(setup, r"HF_HOME|huggingface|/opt/models|snapshot_download|hf_hub|\bcp\b|rsync|wget|curl|pip install|download"))
        _show("[4] start_vllm.sh - 모델·캐시", _grep(start, r"HF_HOME|huggingface|/opt/models"))
        _show("[3] start_vllm.sh - nohup/setsid/disown (vLLM 기동 줄 포함 여부)", _grep(start, r"nohup|setsid|disown|vllm serve|VLLM_PID"))
        _show("[5] /workspace 밖 경로·pod ID 의존", _grep(setup + [""] + start, r"/root/|/opt/|/usr/local|/etc/|/home/|POD_ID|RUNPOD_POD"))
        _show("[7] start_vllm.sh - vLLM 인자(vllm serve 앞뒤)", _grep(start, r"gpu-memory|max-model-len|max_model_len|tensor|enforce|quantiz|dtype|--port|--limit|max-num"))

        r = await conn.run("grep -rnE 'CONCURR|Semaphore|max_workers|MAX_CONCURRENT|ThreadPoolExecutor|asyncio.gather' /workspace/server/*.py 2>/dev/null | cut -c1-180", check=False)
        _show("[8] 동시성 관련 코드(/workspace/server/*.py)", str(r.stdout or "").splitlines(), 40)
        r = await conn.run("grep -nE 'CONCURR|WORKERS|MAX_' /workspace/server/.env 2>/dev/null", check=False)
        _show("[8] /workspace/server/.env 동시성 설정", str(r.stdout or "").splitlines(), 20)


async def _wait_deleted(client: httpx.AsyncClient, pod_id: str) -> bool:
    for _ in range(12):
        r = await client.get(f"{runpod._RUNPOD_V2_PODS_URL}/{pod_id}", headers=runpod._auth_headers())
        if r.status_code == 404:
            return True
        await asyncio.sleep(5)
    return False


async def main() -> None:
    if not (settings.RUNPOD_TEMPLATE_ID and settings.RUNPOD_NETWORK_VOLUME_ID and runpod.gpu_type_ids()):
        sys.exit("서버 .env의 새 pod 설정이 비어 있음")
    if await runpod._list_named_pods(NAME):
        sys.exit(f"{NAME} pod이 이미 있음 - 콘솔에서 확인")

    pod_id = None
    try:
        for gpu in runpod.gpu_type_ids():
            status, text, pid = await runpod._try_create_with_gpu(
                gpu, NAME, settings.RUNPOD_TEMPLATE_ID, settings.RUNPOD_NETWORK_VOLUME_ID
            )
            print(f"생성 시도 {gpu}: HTTP {status} {text[:120] if not pid else ''}")
            if pid:
                pod_id = pid
                break
            if status in runpod._ABORT_STATUSES:
                break
        if not pod_id:
            print("pod을 못 잡음 - 점검 불가")
            return
        t0 = time.monotonic()
        if not await runpod._wait_for_ssh_ready(pod_id, timeout_seconds=300.0, interval_seconds=5.0):
            print("SSH가 열리지 않음")
            return
        print(f"SSH 열림 ({time.monotonic() - t0:.0f}초)")
        await _inspect(pod_id)
    finally:
        if pod_id:
            ok = await runpod._delete_pod(pod_id)
            async with httpx.AsyncClient(timeout=30.0) as client:
                gone = ok and await _wait_deleted(client, pod_id)
            print(f"\npod 삭제 {'확인됨' if gone else '확인 못 함 - 콘솔에서 꼭 확인: ' + pod_id}")


if __name__ == "__main__":
    asyncio.run(main())
