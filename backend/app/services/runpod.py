import asyncio
import logging

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
