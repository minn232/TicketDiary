import logging

from apscheduler.schedulers.asyncio import AsyncIOScheduler

from app.core.database import AsyncSessionLocal
from app.services.notification import process_pending_notifications
from app.services.kopis import sync_daily_concerts
from app.services.crawler import send_screenshots_to_llm
from app.services.ticket import sync_ticket_statuses

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


def start_scheduler() -> None:
    scheduler.add_job(_run_pending_notifications, "interval", minutes=1, id="push_notifications", max_instances=1)
    scheduler.add_job(_run_daily_kopis_sync, "cron", hour=4, minute=0, id="daily_kopis_sync", max_instances=1)
    # KST 자정(00:00) = UTC 15:00
    scheduler.add_job(_run_crawl_send, "cron", hour=15, minute=0, id="midnight_crawl_send", max_instances=1)
    scheduler.add_job(_run_ticket_status_sync, "cron", hour=15, minute=5, id="ticket_status_sync", max_instances=1)
    scheduler.start()
    logger.info("알림 스케줄러 시작됨 (1분 간격)")


def stop_scheduler() -> None:
    scheduler.shutdown(wait=False)
    logger.info("알림 스케줄러 종료됨")
