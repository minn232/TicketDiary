import asyncio
import logging
from datetime import datetime, timezone

import asyncssh
import httpx

from app.core.config import settings
from app.core.http_errors import describe_http_error

logger = logging.getLogger(__name__)

_RUNPOD_PODS_URL = "https://rest.runpod.io/v1/pods"
_STOPPED_STATUSES = {"EXITED", "TERMINATED"}


# 시도 순서대로의 후보 pod ID 목록 - 기본 pod(RUNPOD_POD_ID) 먼저, 그다음 보조 pod들. 한 pod이
# 묶인 호스트의 GPU가 차면 그 pod은 계속 못 뜨므로 다른 호스트의 pod으로 넘어가기 위함
def candidate_pod_ids() -> list[str]:
    ids = [settings.RUNPOD_POD_ID, *settings.RUNPOD_FALLBACK_POD_IDS.split(",")]
    return list(dict.fromkeys(i.strip() for i in ids if i.strip()))


# RunPod pod을 재개(resume)시킨다. LLM팀 GPU 비용 절감을 위해 pod을 KST 00시 전후에만
# 띄워두는 정책이라, 크롤링/아티스트 추출 배치 전송 전에 호출해서 미리 깨워둔다.
# 이미 떠있는 상태에서 호출해도 RunPod API가 별 문제 없이 처리함(멱등) - 중복 호출 걱정 없음
# pod_id를 안 주면 기본 pod(수동 스크립트용)
async def start_pod(pod_id: str | None = None) -> bool:
    pod_id = pod_id or settings.RUNPOD_POD_ID
    if not settings.RUNPOD_API_KEY or not pod_id:
        logger.info("RUNPOD_API_KEY/RUNPOD_POD_ID 미설정, pod 시작 건너뜀")
        return False
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(
                f"{_RUNPOD_PODS_URL}/{pod_id}/start",
                headers={"Authorization": f"Bearer {settings.RUNPOD_API_KEY}"},
            )
            response.raise_for_status()
        logger.info(f"[LLM] RunPod pod 시작 요청 성공 (pod={pod_id})")
        return True
    except Exception as e:
        logger.error(f"[LLM] RunPod pod 시작 요청 실패 (pod={pod_id}): {describe_http_error(e)}")
        return False


# pod 상태 조회(REST v1). 응답에 "runtime" 필드가 아예 없어서(10/16 실제 응답 확인) 상태는
# desiredStatus(RUNNING/EXITED/TERMINATED)로만 알 수 있음 - 과금도 이 값 기준
async def _fetch_pod_status(pod_id: str) -> dict:
    async with httpx.AsyncClient(timeout=15.0) as client:
        response = await client.get(
            f"{_RUNPOD_PODS_URL}/{pod_id}",
            headers={"Authorization": f"Bearer {settings.RUNPOD_API_KEY}"},
        )
        response.raise_for_status()
        return response.json()


# stop 요청 뒤 실제로 꺼졌는지 확인. RunPod API가 stop 요청에 200을 줘도 실제 종료는 비동기라
# 시간이 걸릴 수 있고, API 레벨 성공이 실제 종료를 보장하지 않으므로 GET으로 재확인한다
async def _wait_until_actually_stopped(
    pod_id: str, timeout_seconds: float = 120.0, interval_seconds: float = 10.0
) -> bool:
    elapsed = 0.0
    while elapsed < timeout_seconds:
        try:
            data = await _fetch_pod_status(pod_id)
            # 예전엔 runtime 유무로 봤는데 v1 응답엔 그 필드가 없어 항상 바로 "정지됨"이 됐음.
            # 필드가 빠지거나 값이 낯설면 꺼진 걸로 치지 않음(켜진 채 과금되는 쪽이 더 나쁨)
            if data.get("desiredStatus") in _STOPPED_STATUSES:
                return True
        except Exception as e:
            logger.warning(f"pod 상태 확인 중 오류(재시도함): {e}")
        await asyncio.sleep(interval_seconds)
        elapsed += interval_seconds
    return False


# pod 정지 - 밤배치 조기완료 시 즉시 + 자정 배치 종료 후 안전망 + 1시간 뒤 백업까지 여러
# 경로에서 호출됨(멱등이라 중복 호출 무해, 누락이 훨씬 나쁨). 어느 후보가 떠 있는지 기억하지 않고
# 후보 전부에 정지를 보냄. 반환값은 "요청 성공"이 아니라 "전부 실제로 꺼짐"
async def stop_pod() -> bool:
    pod_ids = candidate_pod_ids()
    if not settings.RUNPOD_API_KEY or not pod_ids:
        logger.info("RUNPOD_API_KEY/RUNPOD_POD_ID 미설정, pod 정지 건너뜀")
        return False
    results = [await _stop_one_pod(pod_id) for pod_id in pod_ids]
    return all(results)


async def _stop_one_pod(pod_id: str) -> bool:
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(
                f"{_RUNPOD_PODS_URL}/{pod_id}/stop",
                headers={"Authorization": f"Bearer {settings.RUNPOD_API_KEY}"},
            )
            response.raise_for_status()
        logger.info(f"[LLM] RunPod pod 정지 요청 성공, 실제 정지 확인 중... (pod={pod_id})")
    except Exception as e:
        logger.error(f"[LLM] RunPod pod 정지 요청 실패 (pod={pod_id}): {describe_http_error(e)}")
        return False

    if await _wait_until_actually_stopped(pod_id):
        logger.info(f"[LLM] RunPod pod 실제 정지 확인됨 (pod={pod_id})")
        return True
    logger.error(f"[LLM] RunPod pod 정지 요청은 성공했지만 실제 정지를 확인하지 못함 - 계속 켜져있을 수 있음 (pod={pod_id})")
    return False


# pod을 깨운 직후 llm_server 헬스체크(base+"/health")가 응답할 때까지 폴링, 안 되면 False(다음날 재시도).
# 기본 1500초 = 매 기동 vLLM 재설치(컨테이너 디스크가 stop마다 초기화, 5~10분) + vLLM 준비 최대 10분
# abort_check: 기동 스크립트가 이미 실패했는지 보는 함수(실패 사유 문자열 또는 None) - 스크립트가
# 설치 단계에서 죽어도 health는 530만 내서 1500초를 다 기다린 뒤에야 다음 후보로 넘어갔음(10/16)
async def wait_until_llm_server_ready(
    timeout_seconds: float = 1500.0,
    interval_seconds: float = 10.0,
    abort_check=None,
    abort_check_every: int = 3,
) -> bool:
    if not settings.LLM_CRAWL_URL:
        return False

    health_url = settings.LLM_CRAWL_URL.rsplit("/", 1)[0] + "/health"
    elapsed = 0.0
    polls = 0
    last_status = "응답 없음"
    async with httpx.AsyncClient(timeout=10.0) as client:
        while elapsed < timeout_seconds:
            try:
                response = await client.get(health_url)
                if response.status_code == 200:
                    logger.info(f"[LLM] llm_server 준비 확인됨 (약 {elapsed:.0f}초 소요)")
                    return True
                last_status = f"HTTP {response.status_code}"
            except Exception as e:
                last_status = describe_http_error(e)
            polls += 1
            if abort_check and polls % abort_check_every == 0:
                reason = await abort_check()
                if reason:
                    logger.error(f"[LLM] 기동 스크립트 실패로 준비 대기 중단 (약 {elapsed:.0f}초 시점): {reason}")
                    return False
            await asyncio.sleep(interval_seconds)
            elapsed += interval_seconds

    # 530=cloudflared 터널 없음, 502=터널은 떴는데 llm_server 미기동 등 원인이 달라 마지막 상태를 남김
    logger.error(f"[LLM] llm_server가 {timeout_seconds:.0f}초 안에 준비되지 않음 (마지막 상태: {last_status})")
    return False


# RunPod의 SSH 포트(공인 IP는 고정이어도 22번의 외부 매핑 포트)가 pod을 stop/start(resume)
# 할 때마다 바뀌는 걸 실제로 확인함(같은 세션에서 세 번 바뀜) - .env에 고정값을 박아두면
# 재시작마다 수동으로 고쳐야 해서, 접속 직전에 RunPod API로 그때그때 조회함. 캐싱 안 함 -
# 매 호출 최신값 보장이 중요하고 이 함수는 pod 시작 시퀀스 안에서만 불려 비용도 무시할 만함.
# REST v1의 portMappings는 {"22": 포트} 한 칸뿐인데 pod이 22/tcp와 22/udp를 둘 다 열고 있어서
# 둘 중 아무거나(udp일 때가 많음) 들어옴 → udp 포트로 접속해 Connection refused(10/16 확인,
# tcp 40162/udp 40163). GraphQL은 포트별 type을 주므로 거기서 tcp 22만 고름
_RUNPOD_GRAPHQL_URL = "https://api.runpod.io/graphql"
_SSH_PORTS_QUERY = (
    "query($id: String!) { pod(input: {podId: $id}) "
    "{ runtime { ports { ip isIpPublic privatePort publicPort type } } } }"
)


async def _fetch_ssh_endpoint(pod_id: str) -> tuple[str, int]:
    async with httpx.AsyncClient(timeout=15.0) as client:
        response = await client.post(
            _RUNPOD_GRAPHQL_URL,
            headers={"Authorization": f"Bearer {settings.RUNPOD_API_KEY}"},
            json={"query": _SSH_PORTS_QUERY, "variables": {"id": pod_id}},
        )
        response.raise_for_status()
        data = response.json()
    pod = (data.get("data") or {}).get("pod") or {}
    ports = (pod.get("runtime") or {}).get("ports") or []
    for port in ports:
        if port.get("privatePort") == 22 and port.get("type") == "tcp" and port.get("isIpPublic"):
            return port["ip"], int(port["publicPort"])
    # pod이 막 시작된 직후엔 runtime/포트가 아직 안 잡혀있을 수 있음 - 호출부
    # (_wait_for_ssh_ready)가 이미 재시도 루프라 예외만 던지면 다음 폴링에서 다시 조회됨
    raise RuntimeError("pod의 SSH 접속 정보(공인 IP의 22/tcp)가 아직 준비되지 않음")


# Container Start Command 자동화가 리스크로 무산돼(pod 편집이 리셋 유발) SSH 원격 실행으로
# 대체함. known_hosts=None으로 호스트키 검증 생략 - 우리가 통제하는 전용 pod 하나뿐이라
# 안 바뀔 걸로 보이지만 100% 확신은 못 해서, 바뀌어도 자동화가 안 끊기게 일부러 뺌.
async def _ssh_connect(pod_id: str, **overrides):
    host, port = await _fetch_ssh_endpoint(pod_id)
    return await asyncssh.connect(
        host,
        port=port,
        username=settings.RUNPOD_SSH_USER,
        client_keys=[settings.RUNPOD_SSH_KEY_PATH],
        known_hosts=None,
        **overrides,
    )


# pod은 켜졌어도 OS/SSH 데몬이 뜨는 데 시간이 걸릴 수 있어 SSH 접속 자체가 될 때까지 폴링
async def _wait_for_ssh_ready(
    pod_id: str | None = None, timeout_seconds: float = 180.0, interval_seconds: float = 10.0
) -> bool:
    pod_id = pod_id or settings.RUNPOD_POD_ID
    if not settings.RUNPOD_API_KEY or not pod_id or not settings.RUNPOD_SSH_KEY_PATH:
        return False

    elapsed = 0.0
    last_error = "시도 없음"
    while elapsed < timeout_seconds:
        try:
            async with await _ssh_connect(pod_id, connect_timeout=10):
                logger.info(f"[LLM] SSH 접속 준비 확인됨 (pod={pod_id}, 약 {elapsed:.0f}초 소요)")
                return True
        except Exception as e:
            last_error = describe_http_error(e)
        await asyncio.sleep(interval_seconds)
        elapsed += interval_seconds

    # Permission denied(키 불일치)와 연결 거부/포트 미할당(아직 부팅 중)은 대응이 달라 마지막 예외를 남김
    logger.error(f"[LLM] SSH가 {timeout_seconds:.0f}초 안에 준비되지 않음 (pod={pod_id}, 마지막 오류: {last_error})")
    return False


# pod에 SSH로 접속해 /workspace/start_vllm.sh(vLLM+llm_server+cloudflared 기동)를 tmux
# 세션으로 원격 실행 - nohup은 세션이 사라져 실행 중 개입할 방법이 없어서, tmux면 나중에
# `tmux attach -t llm_start`로 들어와 같은 화면을 보고 타이핑도 할 수 있음. 재실행 시 이전
# 세션과 충돌 방지로 먼저 kill-session 정리, 실제 준비 확인은 wait_until_llm_server_ready()가 함
_TMUX_SESSION = "llm_start"
# start_vllm.sh는 vLLM을 `> vllm.log 2>&1 &`로 떼어놔서 llm_start 세션에 붙어도 래퍼 스크립트
# 안내문만 보이고 vLLM 실시간 로그는 안 보임 - 로그를 따라가는 tmux 세션을 하나 더 둠.
# `tail -F`(--retry 포함)라 vllm.log가 아직 없어도 생기는 대로 알아서 따라붙음
_TMUX_LOG_SESSION = "vllm_log"
_VLLM_LOG_PATH = "/workspace/server/vllm.log"


# 스크립트 출력 로그를 pod·실행 시각별로 분리 - 주/보조 pod, 03시/07시 실행이 한 파일을 덮어써서
# 남은 로그가 어느 실행 것인지 알 수 없었음(10/16 LLM팀 지적)
def _start_log_path(pod_id: str) -> str:
    return f"/workspace/start_vllm_remote_{pod_id}_{datetime.now(timezone.utc):%m%d_%H%M}.log"


# 스크립트가 실패하면 "ERROR: ..." 줄을 남김(setup_local.sh 실패, GPU 없음 등) - 그 줄이 보이면
# 더 기다려도 안 뜨므로 바로 포기. SSH 자체가 안 되면 판단 보류(None)하고 health 대기를 이어감
async def _start_script_failure(pod_id: str, log_path: str) -> str | None:
    try:
        async with await _ssh_connect(pod_id, connect_timeout=10) as conn:
            result = await conn.run(f"grep -m1 '^ERROR' {log_path}", check=False)
    except Exception:
        return None
    line = str(result.stdout or "").strip()
    return line[:300] or None


async def run_start_script_via_ssh(pod_id: str | None = None, log_path: str | None = None) -> bool:
    pod_id = pod_id or settings.RUNPOD_POD_ID
    if not settings.RUNPOD_API_KEY or not pod_id or not settings.RUNPOD_SSH_KEY_PATH:
        logger.info("RUNPOD_API_KEY/POD_ID/SSH_KEY_PATH 미설정, 원격 실행 건너뜀")
        return False
    log_path = log_path or _start_log_path(pod_id)
    try:
        async with await _ssh_connect(pod_id, connect_timeout=15) as conn:
            # tmux는 /workspace 밖에 설치돼서 pod을 stop/start하면 사라짐 - 없으면 아래 new-session이
            # 조용히 실패해(check=False) start_vllm.sh가 아예 안 돌므로 매번 먼저 확인해 설치
            await _run_remote(
                conn,
                "tmux 설치 확인",
                "command -v tmux >/dev/null || (apt-get update -qq && apt-get install -y -qq tmux)",
            )
            await conn.run(f"tmux kill-session -t {_TMUX_SESSION} 2>/dev/null; true", check=False)
            await _run_remote(
                conn,
                "start_vllm.sh 세션 생성",
                f"tmux new-session -d -s {_TMUX_SESSION} -c /workspace "
                f"'bash start_vllm.sh 2>&1 | tee {log_path}'",
            )
            await conn.run(f"tmux kill-session -t {_TMUX_LOG_SESSION} 2>/dev/null; true", check=False)
            await _run_remote(
                conn,
                "vLLM 로그 세션 생성",
                f"tmux new-session -d -s {_TMUX_LOG_SESSION} "
                f"'tail -n 50 -F {_VLLM_LOG_PATH}'",
            )
        logger.info(
            f"[LLM] start_vllm.sh 원격 실행 요청 완료 (pod={pod_id}, tmux 세션 '{_TMUX_SESSION}'=스크립트 진행상황, "
            f"'{_TMUX_LOG_SESSION}'=vLLM 실시간 로그, 둘 다 SSH로 attach 가능, 스크립트 로그={log_path})"
        )
        return True
    except Exception as e:
        logger.error(f"[LLM] start_vllm.sh 원격 실행 실패 (pod={pod_id}): {describe_http_error(e)}")
        return False


# check=False라 실패해도 예외가 안 나서(tmux 미설치로 세션이 안 만들어져 start_vllm.sh가 조용히
# 안 도는 경우 등) 종료 코드와 stderr를 남겨 원인이 보이게 함
async def _run_remote(conn, label: str, command: str) -> None:
    result = await conn.run(command, check=False)
    if result.exit_status != 0:
        logger.error(f"[LLM] 원격 명령 실패 ({label}): exit={result.exit_status} stderr={str(result.stderr).strip()[:300]}")


# 후보 pod을 순서대로 시작 → SSH 준비 → start_vllm.sh 원격 실행 → llm_server 준비까지 시도해
# 처음 성공한 하나를 씀. 스케줄러의 llm_attempt job이 start_pod() 대신 이 함수를 호출한다
async def start_pod_and_launch_services() -> bool:
    pod_ids = candidate_pod_ids()
    if not settings.RUNPOD_API_KEY or not pod_ids:
        logger.info("RUNPOD_API_KEY/RUNPOD_POD_ID 미설정, pod 시작 건너뜀")
        return False
    for index, pod_id in enumerate(pod_ids, start=1):
        if index > 1:
            logger.warning(f"[LLM] 보조 pod으로 재시도 ({index}/{len(pod_ids)}, pod={pod_id})")
        if await _start_and_launch_one(pod_id):
            return True
    logger.error(f"[LLM] 후보 pod {len(pod_ids)}개 모두 기동 실패")
    return False


async def _start_and_launch_one(pod_id: str) -> bool:
    if not await start_pod(pod_id):
        # start 자체가 실패하면(GPU 부족 등) 안 켜진 상태라 정지할 필요 없음
        return False
    if not settings.RUNPOD_SSH_KEY_PATH:
        # SSH 설정이 아직 없으면(과도기) pod만 켜고 끝 - LLM팀이 수동으로 start_vllm.sh를
        # 돌려야 하는 예전 방식 그대로 유지되는 것뿐이라 안전하게 건너뜀
        return True
    if await _launch_services(pod_id):
        return True
    # 켜졌는데 못 쓰는 pod은 과금되지 않게 바로 정지하고 다음 후보로 넘어감
    await _stop_one_pod(pod_id)
    return False


async def _launch_services(pod_id: str) -> bool:
    if not await _wait_for_ssh_ready(pod_id):
        logger.error(f"[LLM] pod은 켜졌지만 SSH 접속이 준비되지 않아 원격 실행을 포기함 (pod={pod_id})")
        return False
    log_path = _start_log_path(pod_id)
    if not await run_start_script_via_ssh(pod_id, log_path):
        return False
    # 후보 모두 같은 cloudflared 터널이라 health URL은 같음. 여기서 확인해야 vLLM이 안 뜬 pod을
    # 버리고 다음 후보로 넘어갈 수 있음(호출부의 준비 대기는 이미 떠 있어 바로 통과)
    if settings.LLM_CRAWL_URL and not await wait_until_llm_server_ready(
        abort_check=lambda: _start_script_failure(pod_id, log_path)
    ):
        return False
    return True
