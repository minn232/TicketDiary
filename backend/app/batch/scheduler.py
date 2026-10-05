import logging
import time

from apscheduler.schedulers.asyncio import AsyncIOScheduler

from app.core.config import settings
from app.core.database import AsyncSessionLocal
from app.services.notification import process_pending_notifications
from app.services.kopis import sync_daily_concerts
from app.services.artist_normalization import normalize_pending_artists
from app.services.crawler import (
    retry_festival_lineup_checks,
    retry_pending_crawls,
    send_posters_for_artist_extraction,
    send_screenshots_to_llm,
)
from app.services.diary import send_diary_requests_to_llm
from app.services.preview_tracks import warm_preview_catalogs
from app.services.setlist import retry_real_setlist_generation
from app.services.social import cleanup_ended_concert_follows
from app.services.ticket import sync_ticket_statuses
from app.services.lastfm import sync_artist_similarities, sync_artist_genres
from app.services.llm_batch_state import (
    describe_llm_batch_state,
    is_llm_batch_idle,
    mark_all_sent_for_tonight,
    mark_stopped_early,
    reset_llm_night_state,
)
from app.services.runpod import start_pod_and_launch_services, stop_pod, wait_until_llm_server_ready

logger = logging.getLogger(__name__)

scheduler = AsyncIOScheduler()


async def _run_pending_notifications() -> None:
    try:
        async with AsyncSessionLocal() as db:
            await process_pending_notifications(db)
    except Exception:
        logger.exception("알림 스케줄러 실행 오류")


async def _run_daily_kopis_sync() -> None:
    try:
        async with AsyncSessionLocal() as db:
            await sync_daily_concerts(db)
        logger.info("KOPIS 일별 동기화 완료")
    except Exception:
        logger.exception("KOPIS 일별 동기화 오류")


# LLM 배치 한 번의 시도: pod 시작 -> llm_server 준비 대기 -> 크롤/아티스트/일기 전송을 한 job으로
# 이어서 처리. 고정 시각 체인(pod_start 후 20~30분 뒤 전송)은 콜드스타트가 길어지면 어긋나서 묶음.
# pod이 못 뜨거나 llm_server가 준비 안 되면 이번 시도는 포기하고 다음날 재시도(전송 대상은 DB 조건으로
# 다시 잡힘). GPU가 잡혔는데 llm_server가 안 뜬 경우엔 켜진 채 과금되지 않게 바로 정지한다
async def _run_llm_attempt() -> None:
    started = time.monotonic()
    try:
        # 그날 LLM 조기정지 판단 기준을 초기화 (llm_batch_state.py) - 실패해도 무해함
        # (실패하면 아래에서 바로 return이라 idle 판단이 쓰일 일이 없음)
        await reset_llm_night_state()
        logger.info("[LLM] 배치 시도 시작")
        # pod 시작 + SSH 원격으로 start_vllm.sh 실행까지 한 번에 (LLM팀 Container Start
        # Command 자동화가 무산되면서 SSH 방식으로 대체함)
        if not await start_pod_and_launch_services():
            logger.warning(
                f"[LLM] 배치 시도 실패(pod 시작/원격 실행, {time.monotonic() - started:.0f}초) - 다음날 재시도"
            )
            # start 요청 자체가 실패한 경우엔 이미 꺼져있어 무해하고(멱등), SSH 단계 실패면 켜진 pod을 정리
            await stop_pod()
            return
        launched = time.monotonic()
        # LLM_CRAWL_URL 미설정이면 준비 대기 불필요(전송 함수들이 알아서 건너뜀)
        if settings.LLM_CRAWL_URL and not await wait_until_llm_server_ready():
            logger.warning(
                f"[LLM] 배치 시도 실패(llm_server 준비 안 됨, {time.monotonic() - started:.0f}초) - 다음날 재시도"
            )
            await stop_pod()
            return
        ready = time.monotonic()
        # 단계별 전송 건수 - 실패한 단계는 0으로 남고 원인은 각 전송 함수의 에러 로그에 있음
        sent = {"크롤": 0, "아티스트": 0, "일기": 0}
        try:
            sent["크롤"] = await send_screenshots_to_llm()
        except Exception:
            logger.exception("[LLM] 크롤링 스크린샷 전송 오류")
        try:
            sent["아티스트"] = await send_posters_for_artist_extraction()
        except Exception:
            logger.exception("[LLM] 포스터 아티스트 추출 요청 전송 오류")
        try:
            sent["일기"] = await send_diary_requests_to_llm()
        except Exception:
            logger.exception("[LLM] 일기 생성 요청 전송 오류")
        finally:
            # 예정된 전송 3개 중 마지막 - 성공/실패 무관하게 "이번 전송은 이걸로 끝"을 표시해야
            # 정확한 건수 매칭(llm_batch_state.py)이 조기 정지를 판단할 수 있음
            await mark_all_sent_for_tonight()
        logger.info(
            f"[LLM] 배치 시도 전송 완료 - 크롤 {sent['크롤']}건, 아티스트 {sent['아티스트']}건, 일기 {sent['일기']}건 "
            f"(pod 기동 {launched - started:.0f}초, 서버 준비 {ready - launched:.0f}초, 전송 {time.monotonic() - ready:.0f}초)"
        )
    except Exception:
        logger.exception("[LLM] 배치 시도 오류")


async def _run_pod_stop() -> None:
    try:
        stopped = await stop_pod()
        logger.info(f"[LLM] 정해진 시각 정지 - 정지 확인={stopped}, {await describe_llm_batch_state()}")
    except Exception:
        logger.exception("[LLM] RunPod pod 정지 오류")


# 정확한 건수 매칭(웹훅에서 즉시 정지)이 못 잡은 경우를 위한 안전망 - 유휴 5분 감지되면
# 05시 정지보다 먼저 정지. stop_pod()이 실제 정지를 못 확인하면 다음 tick에서 재시도됨
async def _run_llm_idle_check() -> None:
    try:
        if not await is_llm_batch_idle(idle_minutes=5.0):
            return
        logger.info(f"[LLM] 배치 유휴 5분 감지 - 조기 정지 시도 ({await describe_llm_batch_state()})")
        if await stop_pod():
            await mark_stopped_early()
            logger.info("[LLM] 유휴 감지로 pod 조기 정지 완료 (05시/06시 안전망은 그대로 유지됨)")
    except Exception:
        logger.exception("[LLM] 배치 유휴 감지/조기 정지 오류")


async def _run_ticket_status_sync() -> None:
    try:
        async with AsyncSessionLocal() as db:
            await sync_ticket_statuses(db)
    except Exception:
        logger.exception("티켓 상태 자동 전환 오류")


async def _run_concert_follow_cleanup() -> None:
    try:
        async with AsyncSessionLocal() as db:
            await cleanup_ended_concert_follows(db)
    except Exception:
        logger.exception("찜 공연 자동 해제 오류")


# 크롤링 재시도 -> 페스티벌 라인업 재확인을 한 job으로 이음. 둘 다 브라우저를 동시 2개씩 띄우는데
# 서버 RAM이 1.9GB/스왑 0이라, 앞 작업이 길어져 고정 시각이 겹치면 4개가 동시에 떠 OOM 위험이 있음.
# 한 단계가 실패해도 다음 단계는 돌아야 해서 각각 따로 감쌈
async def _run_crawl_group() -> None:
    try:
        await retry_pending_crawls()
    except Exception:
        logger.exception("크롤링 재시도 오류")
    try:
        await retry_festival_lineup_checks()
    except Exception:
        logger.exception("페스티벌 라인업 재확인 오류")


# Last.fm 유사 아티스트 -> 장르 캐싱을 한 job으로 이음. 고정 시각(20분/22분)일 땐 유사도가 22분을
# 넘기면 두 작업이 Last.fm API를 동시에 호출했음(10/4 실측 약 1분 겹침). 한쪽이 실패해도 나머지는 진행
async def _run_lastfm_sync() -> None:
    try:
        await sync_artist_similarities()
    except Exception:
        logger.exception("Last.fm 아티스트 유사도 동기화 오류")
    try:
        await sync_artist_genres()
    except Exception:
        logger.exception("Last.fm 아티스트 장르 동기화 오류")


async def _run_real_setlist_backfill() -> None:
    try:
        await retry_real_setlist_generation()
    except Exception:
        logger.exception("실제 셋리스트 자동 채움 오류")


async def _run_preview_warmup() -> None:
    try:
        logger.info(f"미리듣기 곡 목록 미리 받기 완료: {await warm_preview_catalogs()}")
    except Exception:
        logger.exception("미리듣기 곡 목록 미리 받기 오류")


# 정규화가 끝난 뒤 미리듣기 캐시를 받아야 그날 LLM/정규화로 바뀐 아티스트 기준으로 받아짐 -
# 정규화 소요 시간(MusicBrainz 초당 1건 제한)이 큐 크기에 따라 들쭉날쭉해 고정 시각 대신 한 job으로 이음.
# 정규화가 실패해도 warmup은 돌아야 해서 각각 따로 감쌈
async def _run_musicbrainz_normalize_then_warmup() -> None:
    try:
        stats = await normalize_pending_artists()
        logger.info(f"MusicBrainz 아티스트 정규화 배치 완료: {stats}")
    except Exception:
        logger.exception("MusicBrainz 아티스트 정규화 배치 오류")
    await _run_preview_warmup()


def start_scheduler() -> None:
    scheduler.add_job(_run_pending_notifications, "interval", minutes=1, id="push_notifications", max_instances=1)
    # 스케줄러 시간대는 UTC라 hour는 KST-9 (KST 자정(00:00) = UTC 15:00)
    scheduler.add_job(_run_daily_kopis_sync, "cron", hour=15, minute=0, id="daily_kopis_sync", max_instances=1)
    # 티켓 상태 자동 전환 (KST 00:10)
    scheduler.add_job(_run_ticket_status_sync, "cron", hour=15, minute=10, id="ticket_status_sync", max_instances=1)
    # 찜한 공연 중 이미 종료된 공연 자동 해제 (KST 00:12)
    scheduler.add_job(_run_concert_follow_cleanup, "cron", hour=15, minute=12, id="concert_follow_cleanup", max_instances=1)
    # 크롤 배치 2종(서버에서 9/12부터 정지 중 - LLM 배치 반영 끝난 뒤에만 주석 해제할 것):
    # 찜한 공연 중 아직 ticketing_date 못 얻은 것들 크롤링 재시도 + event_type=FESTIVAL 공연들의
    # 라인업(출연진) 변경 여부 재확인을 이어서 실행 (KST 00:15)
    # scheduler.add_job(_run_crawl_group, "cron", hour=15, minute=15, id="crawl_group", max_instances=1)
    # 신규 아티스트 Last.fm 유사 아티스트 캐싱 -> 장르 태그 캐싱(결산 "선호 장르"용)을 이어서 실행 (KST 00:20)
    scheduler.add_job(_run_lastfm_sync, "cron", hour=15, minute=20, id="lastfm_sync", max_instances=1)
    # 콘서트 종료 후 14일간, 아직 안 채워진 실제 셋리스트를 매일 자동 재시도 (KST 00:40)
    scheduler.add_job(_run_real_setlist_backfill, "cron", hour=15, minute=40, id="real_setlist_backfill", max_instances=1)
    # LLM 배치 시도: pod 시작 -> llm_server 준비 대기 -> 크롤/아티스트/일기 전송 (KST 03:00 = UTC 18:00).
    # 00시대 배치(크롤 재시도/라인업 재확인 등)가 만든 새 스크린샷이 같은 날 바로 전송되는 시각.
    # RUNPOD_API_KEY/RUNPOD_POD_ID 미설정이면 start_pod_and_launch_services()가 알아서 아무것도 안 함
    scheduler.add_job(_run_llm_attempt, "cron", hour=18, minute=0, id="llm_attempt", max_instances=1)
    # 정확한 건수 매칭(웹훅에서 즉시 정지)이 못 잡는 경우를 위한 유휴시간 안전망 - 3분 간격 확인
    # (KST 03:00~04:57). 전송이 끝난 뒤(all_sent_at)에만 판정하므로 콜드스타트 중 오판은 없음
    scheduler.add_job(
        _run_llm_idle_check, "cron", hour="18-19", minute="*/3", id="llm_idle_check", max_instances=1
    )
    # 안전망 정지 (KST 05:00 = UTC 20:00)
    scheduler.add_job(_run_pod_stop, "cron", hour=20, minute=0, id="pod_stop", max_instances=1)
    # stop 실패(네트워크 오류 등) 대비 백업 - GPU가 켜진 채 방치되는 비용 누수를 막는 게
    # 목적이라 이미 꺼져있어도 다시 호출하는 게 안전함 (KST 06:00 = UTC 21:00)
    scheduler.add_job(_run_pod_stop, "cron", hour=21, minute=0, id="pod_stop_backup", max_instances=1)
    # 웹훅들이 쌓아둔 아티스트 정규화 큐(pending)를 MusicBrainz로 확인한 뒤, 이어서 티켓 있는
    # 공연 아티스트의 iTunes 미리듣기 곡 목록을 미리 캐시(첫 재생 지연 방지) - pod_stop 직후로 잡아
    # 콜백이 다 들어온 뒤에 처리되게 함 (KST 05:10 = UTC 20:10)
    scheduler.add_job(
        _run_musicbrainz_normalize_then_warmup, "cron", hour=20, minute=10, id="musicbrainz_normalize", max_instances=1
    )
    scheduler.start()
    logger.info("알림 스케줄러 시작됨 (1분 간격)")


def stop_scheduler() -> None:
    scheduler.shutdown(wait=False)
    logger.info("알림 스케줄러 종료됨")
