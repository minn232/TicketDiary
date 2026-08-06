import logging

from apscheduler.schedulers.asyncio import AsyncIOScheduler

from app.core.config import settings
from app.core.database import AsyncSessionLocal
from app.services.notification import process_pending_notifications
from app.services.kopis import sync_daily_concerts
from app.services.crawler import (
    retry_festival_lineup_checks,
    retry_pending_crawls,
    send_posters_for_artist_extraction,
    send_screenshots_to_llm,
)
from app.services.diary import send_diary_requests_to_llm
from app.services.ticket import sync_ticket_statuses
from app.services.lastfm import sync_artist_similarities, sync_artist_genres
from app.services.runpod import start_pod_and_launch_services, stop_pod, wait_until_llm_server_ready

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


async def _run_pod_start() -> None:
    try:
        # pod 시작 + SSH 원격으로 start_all.sh 실행까지 한 번에 (LLM팀 Container Start
        # Command 자동화가 무산되면서 SSH 방식으로 대체함, 2026-08-06)
        await start_pod_and_launch_services()
    except Exception as e:
        logger.error(f"RunPod pod 시작 오류: {e}")


async def _run_pod_stop() -> None:
    try:
        await stop_pod()
    except Exception as e:
        logger.error(f"RunPod pod 정지 오류: {e}")


async def _run_crawl_send() -> None:
    try:
        # LLM_CRAWL_URL 미설정이면 send_screenshots_to_llm()이 알아서 건너뛰므로 대기 불필요.
        # 설정돼 있으면 pod이 막 깨어난 직후일 수 있어(모델 로딩 시간) 준비될 때까지 기다렸다가
        # 전송 - 타임아웃 안에 준비 안 되면 이번 배치는 건너뛰고 다음날 재시도(기존 실패 처리와 동일)
        if settings.LLM_CRAWL_URL and not await wait_until_llm_server_ready():
            logger.warning("llm_server 준비 안 됨, 이번 크롤링 전송은 건너뛰고 다음날 재시도")
            return
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


async def _run_festival_lineup_check() -> None:
    try:
        await retry_festival_lineup_checks()
    except Exception as e:
        logger.error(f"페스티벌 라인업 재확인 오류: {e}")


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
        # crawl_send와 동일한 이유로 대기 - 이미 위에서 한 번 기다렸을 가능성이 높지만
        # (같은 pod, 두 배치 사이 20분 텀) 짧게 재확인하는 정도라 비용 거의 없음
        if settings.LLM_ARTIST_URL and not await wait_until_llm_server_ready():
            logger.warning("llm_server 준비 안 됨, 이번 아티스트 추출 전송은 건너뛰고 다음날 재시도")
            return
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
    # LLM팀 GPU pod을 배치 시작 10분 전에 미리 깨워둠 (KST 23:50 = UTC 14:50, 전날 기준).
    # RUNPOD_API_KEY/RUNPOD_POD_ID 미설정이면 start_pod_and_launch_services()가 알아서 아무것도 안 함
    scheduler.add_job(_run_pod_start, "cron", hour=14, minute=50, id="pod_start", max_instances=1)
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
    # event_type=FESTIVAL 공연들의 라인업(출연진) 변경 여부를 매일 재확인 (KST 00:35)
    scheduler.add_job(_run_festival_lineup_check, "cron", hour=15, minute=35, id="festival_lineup_check", max_instances=1)
    # 그날 배치 다 끝났으면 pod 정지 (KST 01:00 = UTC 16:00)
    scheduler.add_job(_run_pod_stop, "cron", hour=16, minute=0, id="pod_stop", max_instances=1)
    # stop 실패(네트워크 오류 등) 대비 백업 - 밤새 GPU 켜진 채 방치되는 비용 누수를 막는 게
    # 목적이라 이미 꺼져있어도 다시 호출하는 게 안전함 (KST 02:00 = UTC 17:00)
    scheduler.add_job(_run_pod_stop, "cron", hour=17, minute=0, id="pod_stop_backup", max_instances=1)
    scheduler.start()
    logger.info("알림 스케줄러 시작됨 (1분 간격)")


def stop_scheduler() -> None:
    scheduler.shutdown(wait=False)
    logger.info("알림 스케줄러 종료됨")
