import asyncio
import logging

from fastapi import BackgroundTasks, Depends, FastAPI, status

import inference
from auth import verify_backend_api_key
from callback import send_artist_result, send_crawl_result, send_diary_result
from dedup import is_processed, mark_processed
from normalize import normalize_artist_list, normalize_crawl_result, normalize_diary_text
from schemas import ArtistExtractItem, CrawlAnalyzeItem, DiaryGenerateItem

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="TicketDiary LLM Server")


# inference.py의 함수들은 동기(sync)이고 GPU/CPU를 오래 점유할 수 있으므로,
# 이벤트 루프를 막지 않도록 스레드풀에서 실행한다.
async def _run_sync(func, item):
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(None, func, item)


async def _process_crawl_batch(items: list[CrawlAnalyzeItem]) -> None:
    for item in items:
        # concert_id만으로 dedup하면 페스티벌 라인업이 바뀌어 백엔드가 새 스크린샷을 보내도 "이미
        # 처리한 concert_id"로 보고 영구히 스킵하게 됨. screenshot_url을 키에 포함시켜, 백엔드가
        # 라인업 변경 감지 시 새 URL(버전별 S3 키)로 보내는 걸 자연스럽게 새 작업으로 인식하게 함
        dedup_key = f"{item.concert_id}:{item.screenshot_url}"
        if is_processed("crawl", dedup_key):
            logger.info(f"[crawl] 이미 처리 완료, 스킵: {item.concert_id}")
            continue
        try:
            raw = await _run_sync(inference.analyze_crawl_screenshot, item)
            body = normalize_crawl_result(raw)
            await send_crawl_result(item.concert_id, body)
            mark_processed("crawl", dedup_key)
        except Exception:
            logger.exception(f"[crawl] 처리 실패, 다음날 배치에서 재시도됨: {item.concert_id}")


async def _process_artist_batch(items: list[ArtistExtractItem]) -> None:
    for item in items:
        if is_processed("artist", item.concert_id):
            logger.info(f"[artist] 이미 처리 완료, 스킵: {item.concert_id}")
            continue
        try:
            raw = await _run_sync(inference.extract_artists_from_poster, item)
            artist_name = normalize_artist_list(raw)
            await send_artist_result(item.concert_id, {"artist_name": artist_name})
            mark_processed("artist", item.concert_id)
        except Exception:
            logger.exception(f"[artist] 처리 실패, 다음날 배치에서 재시도됨: {item.concert_id}")


async def _process_diary_batch(items: list[DiaryGenerateItem]) -> None:
    for item in items:
        if is_processed("diary", item.ticket_id):
            logger.info(f"[diary] 이미 처리 완료, 스킵: {item.ticket_id}")
            continue
        try:
            raw = await _run_sync(inference.generate_diary_text, item)
            diary = normalize_diary_text(raw)
            await send_diary_result(item.ticket_id, {"diary": diary})
            mark_processed("diary", item.ticket_id)
        except Exception:
            logger.exception(f"[diary] 처리 실패, 다음날 배치에서 재시도됨: {item.ticket_id}")


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
