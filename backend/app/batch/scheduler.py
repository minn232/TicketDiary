import logging

from apscheduler.schedulers.asyncio import AsyncIOScheduler

from app.core.database import AsyncSessionLocal
from app.services.notification import process_pending_notifications
from app.services.kopis import sync_daily_concerts
from app.services.crawler import retry_pending_crawls, send_posters_for_artist_extraction, send_screenshots_to_llm
from app.services.diary import send_diary_requests_to_llm
from app.services.ticket import sync_ticket_statuses
from app.services.lastfm import sync_artist_similarities, sync_artist_genres

logger = logging.getLogger(__name__)

scheduler = AsyncIOScheduler()


async def _run_pending_notifications() -> None:
    try:
        async with AsyncSessionLocal() as db:
            await process_pending_notifications(db)
    except Exception as e:
        logger.error(f"알림 스케줄러 실행 오류: {e}")


async def _run_daily_kopis_sync() -> None:
    try:
        async with AsyncSessionLocal() as db:
            await sync_daily_concerts(db)
        logger.info("KOPIS 일별 동기화 완료")
    except Exception as e:
        logger.error(f"KOPIS 일별 동기화 오류: {e}")


async def _run_crawl_send() -> None:
    try:
        await send_screenshots_to_llm()
    except Exception as e:
        logger.error(f"크롤링 스크린샷 전송 오류: {e}")


async def _run_ticket_status_sync() -> None:
    try:
        async with AsyncSessionLocal() as db:
            await sync_ticket_statuses(db)
    except Exception as e:
        logger.error(f"티켓 상태 자동 전환 오류: {e}")


async def _run_crawl_retry() -> None:
    try:
        await retry_pending_crawls()
    except Exception as e:
        logger.error(f"크롤링 재시도 오류: {e}")


async def _run_artist_similarity_sync() -> None:
    try:
        await sync_artist_similarities()
    except Exception as e:
        logger.error(f"Last.fm 아티스트 유사도 동기화 오류: {e}")


async def _run_artist_genre_sync() -> None:
    try:
        await sync_artist_genres()
    except Exception as e:
        logger.error(f"Last.fm 아티스트 장르 동기화 오류: {e}")


async def _run_artist_extraction_send() -> None:
    try:
        await send_posters_for_artist_extraction()
    except Exception as e:
        logger.error(f"포스터 아티스트 추출 요청 전송 오류: {e}")


async def _run_diary_send() -> None:
    try:
        await send_diary_requests_to_llm()
    except Exception as e:
        logger.error(f"일기 생성 요청 전송 오류: {e}")


def start_scheduler() -> None:
    scheduler.add_job(_run_pending_notifications, "interval", minutes=1, id="push_notifications", max_instances=1)
    # KST 자정(00:00) = UTC 15:00
    scheduler.add_job(_run_daily_kopis_sync, "cron", hour=15, minute=0, id="daily_kopis_sync", max_instances=1)
    # KOPIS 동기화와 부하가 겹치지 않도록 5분 뒤로 미룸 (KST 00:05)
    scheduler.add_job(_run_crawl_send, "cron", hour=15, minute=5, id="midnight_crawl_send", max_instances=1)
    scheduler.add_job(_run_ticket_status_sync, "cron", hour=15, minute=10, id="ticket_status_sync", max_instances=1)
    # 찜한 공연 중 아직 ticketing_date 못 얻은 것들 크롤링 재시도 (KST 00:15)
    scheduler.add_job(_run_crawl_retry, "cron", hour=15, minute=15, id="crawl_retry", max_instances=1)
    # 신규 아티스트 Last.fm 유사 아티스트 캐싱 (KST 00:20)
    scheduler.add_job(_run_artist_similarity_sync, "cron", hour=15, minute=20, id="artist_similarity_sync", max_instances=1)
    # 신규 아티스트 Last.fm 장르 태그 캐싱 (결산 "선호 장르"용, KST 00:22)
    scheduler.add_job(_run_artist_genre_sync, "cron", hour=15, minute=22, id="artist_genre_sync", max_instances=1)
    # 아티스트 정보 없는 신규 공연의 포스터를 VLM팀에 아티스트 추출 요청으로 전송 (KST 00:25)
    scheduler.add_job(_run_artist_extraction_send, "cron", hour=15, minute=25, id="artist_extraction_send", max_instances=1)
    # 요청된 일기 생성 건을 LLM팀에 전송 (LLM팀 서버가 KST 00~01시 사이에만 떠있어 그 시간대로 맞춤, 00:30)
    scheduler.add_job(_run_diary_send, "cron", hour=15, minute=30, id="diary_send", max_instances=1)
    scheduler.start()
    logger.info("알림 스케줄러 시작됨 (1분 간격)")


def stop_scheduler() -> None:
    scheduler.shutdown(wait=False)
    logger.info("알림 스케줄러 종료됨")
