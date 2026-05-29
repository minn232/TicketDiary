import logging

from apscheduler.schedulers.asyncio import AsyncIOScheduler

from app.core.database import AsyncSessionLocal
from app.services.notification import process_pending_notifications

logger = logging.getLogger(__name__)

scheduler = AsyncIOScheduler()


async def _run_pending_notifications() -> None:
    try:
        async with AsyncSessionLocal() as db:
            await process_pending_notifications(db)
    except Exception as e:
        logger.error(f"알림 스케줄러 실행 오류: {e}")


def start_scheduler() -> None:
    scheduler.add_job(_run_pending_notifications, "interval", minutes=1, id="push_notifications")
    scheduler.start()
    logger.info("알림 스케줄러 시작됨 (1분 간격)")


def stop_scheduler() -> None:
    scheduler.shutdown(wait=False)
    logger.info("알림 스케줄러 종료됨")
