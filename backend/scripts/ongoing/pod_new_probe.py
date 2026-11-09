"""[실측] 새 pod 생성→사용→삭제 방식 사전 측정(RunPod v2 API + Global 볼륨). 기존 pod 운영 코드는 건드리지 않음.

v2 API(POST https://api.runpod.io/v2/pods)로 pod을 새로 만들어(템플릿 + Global 볼륨 /workspace 마운트 +
GPU 종류 하나씩 순서대로) 아래를 재고 로그로 남김. v1 REST는 Global 볼륨을 못 붙임(11/9 실측: "network volume not found").
  1. 후보 GPU가 없을 때 응답 형태(GPU별·시도마다 상태코드·본문 기록, 재고가 날 때까지 간격을 두고 재시도)
  2. 생성 성공까지 걸린 시도 횟수·시간(= GPU 재고 빈도 수치)
  3. 생성 직후·SSH 열린 뒤 단건 조회(GET /v2/pods/{id})의 status·ssh 필드
  4. SSH가 열릴 때까지 시간(현재 코드 제한 180초가 충분한지)
  5. start_vllm.sh 실행 → llm_server health 200까지 시간(현재 제한 1500초) - --skip-launch면 생략
  6. 삭제(DELETE) 응답, 삭제 후 단건 조회·이름 목록 응답, 이미 삭제된 pod에 DELETE 한 번 더
  7. /workspace 유지 확인 - SSH 접속 시 /workspace/probe_marker.txt의 이전 값을 읽어 찍고 새 값을 씀
     (두 번째 실행에서 첫 실행 값이 보이면 볼륨 유지가 확인됨)
결과는 scripts/ongoing/out/pod_new_probe_<시각>.json 에도 남김.

주의
- --skip-launch가 아니면 같은 Cloudflare 터널 토큰을 쓰므로 다른 pod이 RUNNING이면 health 트래픽이 섞임
- 중간에 Ctrl+C(SIGINT)·예외가 나도 finally에서 삭제함. 그래도 끝나고 콘솔에서 pod이 남았는지 확인할 것
- 생성 실패는 과금 없음, 성공하면 삭제 전까지 과금

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    nohup venv/bin/python3 scripts/ongoing/pod_new_probe.py \\
        --template-id <템플릿ID> --volume-id <Global 볼륨ID> \\
        --gpus "NVIDIA A40,NVIDIA GeForce RTX 4090,NVIDIA L40S" \\
        [--skip-launch] [--dry-run] > /tmp/pod_probe.log 2>&1 &
  --dry-run: 생성 요청 없이 사전 점검(키·같은 이름 pod 유무)만
  --skip-launch: SSH 열림까지만 재고 start_vllm.sh·health는 생략
"""

import argparse
import asyncio
import json
import logging
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from app.core.config import settings  # noqa: E402
from app.services import runpod  # noqa: E402

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("pod_new_probe")

PODS_URL = runpod._RUNPOD_V2_PODS_URL
OUT_DIR = Path(__file__).resolve().parent / "out"
MARKER = "/workspace/probe_marker.txt"


def _short(text: str, limit: int = 500) -> str:
    text = " ".join(text.split())
    return text if len(text) <= limit else text[:limit] + "..."


async def _get_pod(client: httpx.AsyncClient, pod_id: str) -> dict:
    r = await client.get(f"{PODS_URL}/{pod_id}", headers=runpod._auth_headers())
    out = {"status": r.status_code, "body": _short(r.text, 700)}
    log.info(f"GET /v2/pods/{pod_id}: HTTP {r.status_code} {out['body']}")
    return out


async def _delete_and_verify(client: httpx.AsyncClient, pod_id: str, name: str, report: dict) -> None:
    d: dict = {}
    r = await client.delete(f"{PODS_URL}/{pod_id}", headers=runpod._auth_headers())
    d["delete"] = {"status": r.status_code, "body": _short(r.text)}
    log.info(f"DELETE: HTTP {r.status_code} {_short(r.text)}")
    # 삭제 직후 단건 조회가 어떻게 보이는지(404인지, TERMINATED가 남는지) 몇 초 간격으로 관찰
    d["get_after"] = []
    for _ in range(6):
        await asyncio.sleep(5)
        r = await client.get(f"{PODS_URL}/{pod_id}", headers=runpod._auth_headers())
        d["get_after"].append({"status": r.status_code, "body": _short(r.text, 200)})
        log.info(f"삭제 후 GET: HTTP {r.status_code} {_short(r.text, 200)}")
    r = await client.delete(f"{PODS_URL}/{pod_id}", headers=runpod._auth_headers())
    d["delete_again"] = {"status": r.status_code, "body": _short(r.text)}
    log.info(f"이미 삭제된 pod에 DELETE 재요청: HTTP {r.status_code} {_short(r.text)}")
    remaining = await runpod._list_named_pods(name)
    d["list_by_name_after"] = {"count": len(remaining), "ids": [p.get("id") for p in remaining]}
    log.info(f"이름 목록 조회(삭제 후, TERMINATED 제외): 남은 pod {len(remaining)}개")
    report["delete_check"] = d


async def _marker_check(pod_id: str, report: dict) -> None:
    stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
    try:
        async with await runpod._ssh_connect(pod_id, connect_timeout=15) as conn:
            prev = await conn.run(f"cat {MARKER} 2>/dev/null", check=False)
            await conn.run(f"echo '{stamp} pod={pod_id}' >> {MARKER}", check=False)
            # 볼륨이 실제로 /workspace에 붙었는지(마운트 목록·용량)도 같이 남김
            mount = await conn.run("df -h /workspace | tail -1; ls /workspace | head -20", check=False)
        report["marker_previous"] = str(prev.stdout or "").strip()
        report["workspace_df_ls"] = str(mount.stdout or "").strip()
        log.info(f"/workspace 마커 이전 내용: {report['marker_previous'] or '(없음 - 첫 실행이거나 볼륨 미유지)'}")
        log.info(f"/workspace 상태: {_short(report['workspace_df_ls'], 400)}")
    except Exception as e:
        report["marker_previous"] = f"확인 실패: {e}"


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--template-id", required=True)
    ap.add_argument("--volume-id", required=True, help="Global 볼륨 ID")
    ap.add_argument("--gpus", required=True, help="쉼표 구분 GPU 종류 ID, 앞에 올수록 우선(요청은 하나씩 보냄)")
    ap.add_argument("--name", default="td-llm-probe")
    ap.add_argument("--retry-interval", type=int, default=120, help="한 바퀴(후보 전부) 실패 뒤 재시도 간격(초)")
    ap.add_argument("--max-wait-minutes", type=int, default=60, help="생성 재시도 총 한도")
    ap.add_argument("--skip-launch", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not settings.RUNPOD_API_KEY:
        sys.exit("RUNPOD_API_KEY 미설정")
    if not settings.RUNPOD_SSH_KEY_PATH:
        sys.exit("RUNPOD_SSH_KEY_PATH 미설정 - SSH 측정 불가")

    gpus = [g.strip() for g in args.gpus.split(",") if g.strip()]
    report: dict = {
        "started": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "args": vars(args),
        "create_attempts": [],
    }

    existing = await runpod._list_named_pods(args.name)
    log.info(f"사전 점검: v2 목록 조회 OK, 이름 '{args.name}' 기존 {len(existing)}개")
    if existing:
        sys.exit(f"같은 이름 pod이 이미 있음({[p.get('id') for p in existing]}) - 콘솔에서 확인·삭제 후 다시")
    if args.dry_run:
        print("dry-run 끝(생성 안 함). GPU 후보:", gpus, "템플릿:", args.template_id, "볼륨:", args.volume_id)
        return

    pod_id = None
    async with httpx.AsyncClient(timeout=60.0) as client:
        try:
            t0 = time.monotonic()
            deadline = t0 + args.max_wait_minutes * 60
            while pod_id is None:
                for gpu in gpus:
                    status, text, pid = await runpod._try_create_with_gpu(gpu, args.name, args.template_id, args.volume_id)
                    report["create_attempts"].append(
                        {"at": datetime.now(timezone.utc).isoformat(timespec="seconds"), "gpu": gpu, "status": status, "body": text}
                    )
                    log.info(f"생성 시도 #{len(report['create_attempts'])} ({gpu}): HTTP {status} {text}")
                    if pid:
                        pod_id = pid
                        report["gpu"] = gpu
                        break
                    if status in runpod._ABORT_STATUSES:
                        log.error("설정 문제로 보이는 응답(인증·잔액·본문·429) - 다른 GPU로 해도 같으니 중단")
                        deadline = 0
                        break
                if pod_id or time.monotonic() + args.retry_interval > deadline:
                    break
                await asyncio.sleep(args.retry_interval)
            if pod_id is None:
                log.error("pod을 못 잡은 채 종료 - 측정 중단")

            if pod_id:
                report["pod_id"] = pod_id
                report["seconds_until_created"] = round(time.monotonic() - t0)
                log.info(f"pod 생성됨 id={pod_id} gpu={report['gpu']} (시작부터 {report['seconds_until_created']}초, 시도 {len(report['create_attempts'])}회)")
                report["get_after_create"] = await _get_pod(client, pod_id)
                t1 = time.monotonic()
                # 큰 여유(600초)로 재서 실제 소요를 봄 - 새 호스트면 이미지 pull이 붙을 수 있음
                ssh_ok = await runpod._wait_for_ssh_ready(pod_id, timeout_seconds=600.0, interval_seconds=5.0)
                report["ssh_ready"] = ssh_ok
                report["seconds_ssh"] = round(time.monotonic() - t1)
                log.info(f"SSH {'열림' if ssh_ok else '안 열림'}: {report['seconds_ssh']}초")
                report["get_after_ssh"] = await _get_pod(client, pod_id)
                if ssh_ok:
                    await _marker_check(pod_id, report)
                if ssh_ok and not args.skip_launch:
                    t2 = time.monotonic()
                    launched = await runpod.run_start_script_via_ssh(pod_id)
                    report["script_started"] = launched
                    if launched:
                        # 현재 운영 제한(1500초)보다 길게 재서 실제 소요를 봄
                        ready = await runpod.wait_until_llm_server_ready(timeout_seconds=2400.0)
                        report["health_ready"] = ready
                        report["seconds_health"] = round(time.monotonic() - t2)
                        log.info(f"health {'200' if ready else '실패'}: 스크립트 시작부터 {report['seconds_health']}초")
        finally:
            if pod_id:
                log.info("측정 끝 - pod 삭제")
                try:
                    await _delete_and_verify(client, pod_id, args.name, report)
                except Exception as e:
                    log.error(f"삭제 확인 중 오류 - 콘솔에서 pod이 남았는지 꼭 확인: {e}")
                    report["delete_error"] = str(e)

    OUT_DIR.mkdir(exist_ok=True)
    out = OUT_DIR / f"pod_new_probe_{datetime.now():%Y%m%d_%H%M%S}.json"
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"결과 저장: {out}")


if __name__ == "__main__":
    asyncio.run(main())
