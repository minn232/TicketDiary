import asyncio
import logging
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager

from fastapi import BackgroundTasks, Depends, FastAPI, status

import inference
from auth import verify_backend_api_key
from callback import send_artist_result, send_crawl_result, send_diary_result
from config import settings
from dedup import is_processed, mark_processed
from normalize import normalize_artist_list, normalize_crawl_result, normalize_diary_text
from schemas import ArtistExtractItem, CrawlAnalyzeItem, DiaryGenerateItem

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def _lifespan(_: FastAPI):
    # 기본 executor 크기는 호스트 CPU 코어 수에 따라 달라지는데(min(32, cpu_count+4)),
    # 코어가 적은 인스턴스에서는 이게 BATCH_CONCURRENCY보다 작아서 세마포어가 허용하는
    # 동시 개수만큼 스레드가 실제로 동시에 돌지 못하는 병목이 될 수 있다. 명시적으로
    # BATCH_CONCURRENCY 이상으로 맞춰준다.
    asyncio.get_running_loop().set_default_executor(
        ThreadPoolExecutor(max_workers=max(settings.BATCH_CONCURRENCY, 4))
    )
    yield


app = FastAPI(title="TicketDiary LLM Server", lifespan=_lifespan)

# crawl/artist/diary 배치가 전부 공유하는 동시성 제한. 셋 다 결국 같은 GPU/vLLM
# 인스턴스를 두고 경쟁하므로, 배치 종류와 무관하게 전체 동시 모델 호출 수를 이 값
# 하나로 묶어서 제한한다(설정은 config.py의 BATCH_CONCURRENCY 참고).
_inference_semaphore = asyncio.Semaphore(settings.BATCH_CONCURRENCY)


# inference.py의 함수들은 동기(sync)이고 GPU/CPU를 오래 점유할 수 있으므로,
# 이벤트 루프를 막지 않도록 스레드풀에서 실행한다. 세마포어로 동시 실행 개수를 제한해서
# vLLM에 한꺼번에 너무 많은 요청이 몰리지 않게 한다.
async def _run_sync(func, item):
    loop = asyncio.get_running_loop()
    async with _inference_semaphore:
        return await loop.run_in_executor(None, func, item)


async def _process_crawl_batch(items: list[CrawlAnalyzeItem]) -> None:
    async def _handle(item: CrawlAnalyzeItem) -> None:
        # concert_id만으로 dedup하면 페스티벌 라인업이 바뀌어 백엔드가 새 스크린샷을 보내도 "이미
        # 처리한 concert_id"로 보고 영구히 스킵하게 됨. screenshot_url을 키에 포함시켜, 백엔드가
        # 라인업 변경 감지 시 새 URL(버전별 S3 키)로 보내는 걸 자연스럽게 새 작업으로 인식하게 함
        dedup_key = f"{item.concert_id}:{item.screenshot_url}"
        if is_processed("crawl", dedup_key):
            logger.info(f"[crawl] 이미 처리 완료, 스킵: {item.concert_id}")
            return
        try:
            raw = await _run_sync(inference.analyze_crawl_screenshot, item)
            body = normalize_crawl_result(raw)
            await send_crawl_result(item.concert_id, body)
            mark_processed("crawl", dedup_key)
        except Exception:
            logger.exception(f"[crawl] 처리 실패, 다음날 배치에서 재시도됨: {item.concert_id}")

    # 개별 항목의 실제 모델 호출은 _run_sync 안의 세마포어가 동시 개수를 제한하므로,
    # 여기서는 전부 동시에 스케줄링해도 안전하다(순차로 하나씩 기다릴 필요 없음).
    await asyncio.gather(*(_handle(item) for item in items))


async def _process_artist_batch(items: list[ArtistExtractItem]) -> None:
    async def _handle(item: ArtistExtractItem) -> None:
        if is_processed("artist", item.concert_id):
            logger.info(f"[artist] 이미 처리 완료, 스킵: {item.concert_id}")
            return
        try:
            raw = await _run_sync(inference.extract_artists_from_poster, item)
            artist_name = normalize_artist_list(raw)
            await send_artist_result(item.concert_id, {"artist_name": artist_name})
            mark_processed("artist", item.concert_id)
        except Exception:
            logger.exception(f"[artist] 처리 실패, 다음날 배치에서 재시도됨: {item.concert_id}")

    await asyncio.gather(*(_handle(item) for item in items))


async def _process_diary_batch(items: list[DiaryGenerateItem]) -> None:
    async def _handle(item: DiaryGenerateItem) -> None:
        if is_processed("diary", item.ticket_id):
            logger.info(f"[diary] 이미 처리 완료, 스킵: {item.ticket_id}")
            return
        try:
            raw = await _run_sync(inference.generate_diary_text, item)
            diary = normalize_diary_text(raw)
            await send_diary_result(item.ticket_id, {"diary": diary})
            mark_processed("diary", item.ticket_id)
        except Exception:
            logger.exception(f"[diary] 처리 실패, 다음날 배치에서 재시도됨: {item.ticket_id}")

    await asyncio.gather(*(_handle(item) for item in items))


# 백엔드가 크롤링 스크린샷 배치를 보내는 엔드포인트.
# 요청 바디는 객체가 아니라 순수 JSON 배열 (services/crawler.py의 send_screenshots_to_llm 참고).
@app.post("/crawl-analyze", status_code=status.HTTP_202_ACCEPTED, dependencies=[Depends(verify_backend_api_key)])
async def crawl_analyze(items: list[CrawlAnalyzeItem], background_tasks: BackgroundTasks):
    background_tasks.add_task(_process_crawl_batch, items)
    return {"accepted": len(items)}


# 백엔드가 포스터 아티스트 추출 배치를 보내는 엔드포인트.
@app.post("/artist-extract", status_code=status.HTTP_202_ACCEPTED, dependencies=[Depends(verify_backend_api_key)])
async def artist_extract(items: list[ArtistExtractItem], background_tasks: BackgroundTasks):
    background_tasks.add_task(_process_artist_batch, items)
    return {"accepted": len(items)}


# 백엔드가 일기 생성 요청 배치를 보내는 엔드포인트.
@app.post("/diary-generate", status_code=status.HTTP_202_ACCEPTED, dependencies=[Depends(verify_backend_api_key)])
async def diary_generate(items: list[DiaryGenerateItem], background_tasks: BackgroundTasks):
    background_tasks.add_task(_process_diary_batch, items)
    return {"accepted": len(items)}


# 인증 없이 인스턴스가 살아있는지만 확인하는 헬스체크
@app.get("/health")
async def health():
    return {"status": "ok"}
