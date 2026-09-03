import asyncio
import logging

import asyncssh
import httpx

from app.core.config import settings

logger = logging.getLogger(__name__)

_RUNPOD_PODS_URL = "https://rest.runpod.io/v1/pods"


# RunPod pod을 재개(resume)시킨다. LLM팀 GPU 비용 절감을 위해 pod을 KST 00시 전후에만
# 띄워두는 정책이라, 크롤링/아티스트 추출 배치 전송 전에 호출해서 미리 깨워둔다.
# 이미 떠있는 상태에서 호출해도 RunPod API가 별 문제 없이 처리함(멱등) - 중복 호출 걱정 없음
async def start_pod() -> bool:
    if not settings.RUNPOD_API_KEY or not settings.RUNPOD_POD_ID:
        logger.info("RUNPOD_API_KEY/RUNPOD_POD_ID 미설정, pod 시작 건너뜀")
        return False
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(
                f"{_RUNPOD_PODS_URL}/{settings.RUNPOD_POD_ID}/start",
                headers={"Authorization": f"Bearer {settings.RUNPOD_API_KEY}"},
            )
            response.raise_for_status()
        logger.info("RunPod pod 시작 요청 성공")
        return True
    except Exception as e:
        logger.error(f"RunPod pod 시작 요청 실패: {e}")
        return False


# pod 정지. 매일 자정 배치 종료 후 1회 + 안전장치로 1시간 뒤 백업 job에서 한 번 더 호출됨
# (stop도 멱등이라 이미 정지된 상태에서 또 불러도 무해 - 밤새 GPU 켜진 채 방치되는 비용
# 누수를 막는 게 목적이라 중복 호출보다 누락이 훨씬 나쁨)
async def stop_pod() -> bool:
    if not settings.RUNPOD_API_KEY or not settings.RUNPOD_POD_ID:
        logger.info("RUNPOD_API_KEY/RUNPOD_POD_ID 미설정, pod 정지 건너뜀")
        return False
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(
                f"{_RUNPOD_PODS_URL}/{settings.RUNPOD_POD_ID}/stop",
                headers={"Authorization": f"Bearer {settings.RUNPOD_API_KEY}"},
            )
            response.raise_for_status()
        logger.info("RunPod pod 정지 요청 성공")
        return True
    except Exception as e:
        logger.error(f"RunPod pod 정지 요청 실패: {e}")
        return False


# pod을 깨운 직후엔 vLLM 로딩 시간이 있어 llm_server 헬스체크가 응답할 때까지 폴링함
# (LLM_CRAWL_URL에서 base만 뽑아 "/health" 붙임, 별도 설정 불필요). 타임아웃 안에 준비
# 안 되면 False - 호출부는 이번 배치를 건너뛰고 다음날 재시도되는 기존 설계와 맞물림.
# 기본값 600초(2026-08-27 상향, 원래 300초): start_vllm.sh 자체가 vLLM 준비만 최대 10분까지
# 기다리도록 돼있어(120회×5초) 기존 300초로는 실측 콜드스타트에 못 미쳐 타임아웃 나는 걸 확인함.
async def wait_until_llm_server_ready(timeout_seconds: float = 600.0, interval_seconds: float = 10.0) -> bool:
    if not settings.LLM_CRAWL_URL:
        return False

    health_url = settings.LLM_CRAWL_URL.rsplit("/", 1)[0] + "/health"
    elapsed = 0.0
    async with httpx.AsyncClient(timeout=10.0) as client:
        while elapsed < timeout_seconds:
            try:
                response = await client.get(health_url)
                if response.status_code == 200:
                    logger.info(f"llm_server 준비 확인됨 (약 {elapsed:.0f}초 소요)")
                    return True
            except Exception:
                pass
            await asyncio.sleep(interval_seconds)
            elapsed += interval_seconds

    logger.error(f"llm_server가 {timeout_seconds:.0f}초 안에 준비되지 않음")
    return False


# RunPod의 SSH 포트(공인 IP는 고정이어도 22번의 외부 매핑 포트)가 pod을 stop/start(resume)
# 할 때마다 바뀌는 걸 실제로 확인함(2026-08-27, 같은 세션에서 40154→40077→40110로 세 번
# 바뀜) - .env에 고정값을 박아두면 재시작마다 수동으로 고쳐야 해서, 접속 직전에 RunPod API로
# 그때그때 현재 값을 조회하도록 함. 캐싱 안 함 - 매 호출마다 최신값 보장이 중요하고 이 함수는
# 자주 불리는 게 아니라(pod 시작 시퀀스 안에서만) 비용도 무시할 만함.
async def _fetch_ssh_endpoint() -> tuple[str, int]:
    async with httpx.AsyncClient(timeout=15.0) as client:
        response = await client.get(
            f"{_RUNPOD_PODS_URL}/{settings.RUNPOD_POD_ID}",
            headers={"Authorization": f"Bearer {settings.RUNPOD_API_KEY}"},
        )
        response.raise_for_status()
        data = response.json()
    host = data.get("publicIp")
    port = (data.get("portMappings") or {}).get("22")
    if not host or not port:
        # pod이 막 시작된 직후엔 네트워크 정보가 아직 안 잡혀있을 수 있음(publicIp가 빈
        # 문자열) - 호출부(_wait_for_ssh_ready)가 이미 재시도 루프라 예외만 던지면 자연스럽게
        # 다음 폴링에서 다시 조회됨
        raise RuntimeError("pod의 SSH 접속 정보(publicIp/portMappings)가 아직 준비되지 않음")
    return host, int(port)


# Container Start Command 자동화가 리스크로 무산돼(pod 편집이 리셋 유발) SSH 원격 실행으로
# 대체함. known_hosts=None으로 호스트키 검증 생략 - 우리가 통제하는 전용 pod 하나뿐이라
# 안 바뀔 걸로 보이지만 100% 확신은 못 해서, 바뀌어도 자동화가 안 끊기게 일부러 뺌.
async def _ssh_connect(**overrides):
    host, port = await _fetch_ssh_endpoint()
    return await asyncssh.connect(
        host,
        port=port,
        username=settings.RUNPOD_SSH_USER,
        client_keys=[settings.RUNPOD_SSH_KEY_PATH],
        known_hosts=None,
        **overrides,
    )


# pod은 켜졌어도 OS/SSH 데몬이 뜨는 데 시간이 걸릴 수 있어 SSH 접속 자체가 될 때까지 폴링
async def _wait_for_ssh_ready(timeout_seconds: float = 180.0, interval_seconds: float = 10.0) -> bool:
    if not settings.RUNPOD_API_KEY or not settings.RUNPOD_POD_ID or not settings.RUNPOD_SSH_KEY_PATH:
        return False

    elapsed = 0.0
    while elapsed < timeout_seconds:
        try:
            async with await _ssh_connect(connect_timeout=10):
                logger.info(f"SSH 접속 준비 확인됨 (약 {elapsed:.0f}초 소요)")
                return True
        except Exception:
            pass
        await asyncio.sleep(interval_seconds)
        elapsed += interval_seconds

    logger.error(f"SSH가 {timeout_seconds:.0f}초 안에 준비되지 않음")
    return False


# pod에 SSH로 접속해 start_vllm.sh(vLLM+llm_server+cloudflared 기동)를 원격 실행 - 스크립트가
# vLLM 준비까지 폴링하느라 오래 걸려서 SSH 세션은 바로 반환함. 실제 준비 확인은
# wait_until_llm_server_ready()가 별도로 함.
# 경로 2026-08-27 확인: LLM팀이 /workspace/server/start_all.sh에서 /workspace/start_vllm.sh로
# 옮겨서 갱신함(server/ 밑은 이제 llm_server 앱 코드 전용 - main.py 등)
# tmux 세션(2026-08-27, 기존 nohup+&에서 교체): nohup은 세션 자체가 사라져서 실행 중에
# 진행 상황을 보거나 개입할 방법이 없었음 - tmux로 띄우면 사람이 나중에 SSH로 들어와서
# `tmux attach -t llm_start`로 같은 화면을 실시간으로 보고 타이핑도 할 수 있음(pod에 tmux
# 없으면 최초 1회 설치 필요, `apt-get install -y tmux`). 재실행 시 이전 세션이 남아있으면
# 새로 붙이려던 세션이 충돌하므로 먼저 kill-session으로 정리(스크립트 자체의 [0/3] pkill
# 정리 로직과 같은 이유) - 이미 없으면 에러 없이 조용히 넘어감(`; true`).
_TMUX_SESSION = "llm_start"
# start_vllm.sh는 vLLM 프로세스 자체를 `> vllm.log 2>&1 &`로 백그라운드+로그파일로 떼어놓기
# 때문에(스크립트가 그 사이 curl로 준비상태를 폴링해야 해서), llm_start 세션에 붙어도 래퍼
# 스크립트의 안내 문구만 보이고 vLLM 자체 실시간 로그(요청 처리/생성 진행상황)는 안 보임 -
# 그래서 로그를 실시간으로 따라가는 tmux 세션을 하나 더 둠(vLLM 코드/스크립트는 안 건드림).
# `tail -F`(대문자, --retry 포함)라서 vLLM이 아직 vllm.log를 만들기 전에 이 세션을 먼저
# 띄워도 파일이 생기는 대로 알아서 따라붙음.
_TMUX_LOG_SESSION = "vllm_log"
_VLLM_LOG_PATH = "/workspace/server/vllm.log"


async def run_start_script_via_ssh() -> bool:
    if not settings.RUNPOD_API_KEY or not settings.RUNPOD_POD_ID or not settings.RUNPOD_SSH_KEY_PATH:
        logger.info("RUNPOD_API_KEY/POD_ID/SSH_KEY_PATH 미설정, 원격 실행 건너뜀")
        return False
    try:
        async with await _ssh_connect(connect_timeout=15) as conn:
            await conn.run(f"tmux kill-session -t {_TMUX_SESSION} 2>/dev/null; true", check=False)
            await conn.run(
                f"tmux new-session -d -s {_TMUX_SESSION} -c /workspace "
                "'bash start_vllm.sh 2>&1 | tee start_vllm_remote.log'",
                check=False,
            )
            await conn.run(f"tmux kill-session -t {_TMUX_LOG_SESSION} 2>/dev/null; true", check=False)
            await conn.run(
                f"tmux new-session -d -s {_TMUX_LOG_SESSION} "
                f"'tail -n 50 -F {_VLLM_LOG_PATH}'",
                check=False,
            )
        logger.info(
            f"start_vllm.sh 원격 실행 요청 완료 (tmux 세션 '{_TMUX_SESSION}'=스크립트 진행상황, "
            f"'{_TMUX_LOG_SESSION}'=vLLM 실시간 로그, 둘 다 SSH로 attach 가능)"
        )
        return True
    except Exception as e:
        logger.error(f"start_vllm.sh 원격 실행 실패: {e}")
        return False


# pod 시작 + SSH 준비 대기 + start_vllm.sh 원격 실행까지 한 번에 처리. 스케줄러의 pod_start
# job이 start_pod() 대신 이 함수를 호출한다
async def start_pod_and_launch_services() -> bool:
    if not await start_pod():
        return False
    if not settings.RUNPOD_SSH_KEY_PATH:
        # SSH 설정이 아직 없으면(과도기) pod만 켜고 끝 - LLM팀이 수동으로 start_vllm.sh를
        # 돌려야 하는 예전 방식 그대로 유지되는 것뿐이라 안전하게 건너뜀
        return True
    if not await _wait_for_ssh_ready():
        logger.error("pod은 켜졌지만 SSH 접속이 준비되지 않아 원격 실행을 포기함")
        return False
    return await run_start_script_via_ssh()
