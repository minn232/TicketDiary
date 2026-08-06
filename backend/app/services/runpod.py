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


# pod을 깨운 직후엔 vLLM 모델 로딩 시간이 있어서, llm_server 헬스체크가 응답할 때까지
# 폴링한다. LLM_CRAWL_URL("https://llm.ticket-diary.com/crawl-analyze")에서 base URL만
# 뽑아 "/health"를 붙이는 방식이라 헬스체크용 설정을 따로 추가할 필요 없음.
# 타임아웃 안에 준비 안 되면 False를 반환하고, 호출부(크롤링/아티스트 전송)는 이번 배치를
# 건너뛰면 됨 - 기존에도 실패 시 다음날 재시도되는 설계라 안전하게 맞물림
async def wait_until_llm_server_ready(timeout_seconds: float = 300.0, interval_seconds: float = 10.0) -> bool:
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


# LLM팀 Container Start Command 자동화가 리스크 때문에 무산돼서(pod 편집 자체가 리셋을
# 유발함, 2026-08-06) 백엔드가 SSH로 직접 원격 실행하는 방식으로 대체함.
# known_hosts=None으로 호스트키 검증을 생략함 - pod IP/포트가 우리가 통제하는 전용 pod
# 하나뿐이고(RUNPOD_POD_ID로 지정된 그 pod), "정지/재시작" 방식이라 재생성이 아니면 호스트키가
# 안 바뀔 걸로 보이지만 100% 확신은 못 해서, 매번 바뀌어도 자동화가 안 끊기게 일부러 검증을 뺌
async def _ssh_connect(**overrides):
    return await asyncssh.connect(
        settings.RUNPOD_SSH_HOST,
        port=settings.RUNPOD_SSH_PORT,
        username=settings.RUNPOD_SSH_USER,
        client_keys=[settings.RUNPOD_SSH_KEY_PATH],
        known_hosts=None,
        **overrides,
    )


# pod은 켜졌어도 OS/SSH 데몬이 뜨는 데 시간이 걸릴 수 있어 SSH 접속 자체가 될 때까지 폴링
async def _wait_for_ssh_ready(timeout_seconds: float = 180.0, interval_seconds: float = 10.0) -> bool:
    if not settings.RUNPOD_SSH_HOST or not settings.RUNPOD_SSH_KEY_PATH:
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


# pod에 SSH로 접속해서 start_all.sh(vLLM+llm_server+cloudflared 기동)를 원격 실행한다.
# 스크립트 자체가 vLLM 준비될 때까지 폴링하느라 몇 분씩 걸릴 수 있어서, nohup + & + 표준
# 입출력 리다이렉트로 완전히 백그라운드에 떼어놓고 SSH 세션은 바로 반환하게 함(안 그러면
# SSH 채널이 자식 프로세스의 fd가 다 닫힐 때까지 안 끝남). 실제로 준비됐는지는 이 함수가
# 아니라 wait_until_llm_server_ready()가 별도로 확인함
async def run_start_script_via_ssh() -> bool:
    if not settings.RUNPOD_SSH_HOST or not settings.RUNPOD_SSH_KEY_PATH:
        logger.info("RUNPOD_SSH_* 미설정, 원격 실행 건너뜀")
        return False
    try:
        async with await _ssh_connect(connect_timeout=15) as conn:
            await conn.run(
                "nohup bash /workspace/server/start_all.sh "
                "> /workspace/server/start_all_remote.log 2>&1 < /dev/null &",
                check=False,
            )
        logger.info("start_all.sh 원격 실행 요청 완료")
        return True
    except Exception as e:
        logger.error(f"start_all.sh 원격 실행 실패: {e}")
        return False


# pod 시작 + SSH 준비 대기 + start_all.sh 원격 실행까지 한 번에 처리. 스케줄러의 pod_start
# job이 start_pod() 대신 이 함수를 호출한다
async def start_pod_and_launch_services() -> bool:
    if not await start_pod():
        return False
    if not settings.RUNPOD_SSH_HOST:
        # SSH 설정이 아직 없으면(과도기) pod만 켜고 끝 - LLM팀이 수동으로 start_all.sh를
        # 돌려야 하는 예전 방식 그대로 유지되는 것뿐이라 안전하게 건너뜀
        return True
    if not await _wait_for_ssh_ready():
        logger.error("pod은 켜졌지만 SSH 접속이 준비되지 않아 원격 실행을 포기함")
        return False
    return await run_start_script_via_ssh()
