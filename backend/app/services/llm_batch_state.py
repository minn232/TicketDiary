import logging
from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from app.core.database import AsyncSessionLocal
from app.models.llm_batch_state import LlmNightBatchState

logger = logging.getLogger(__name__)

_SINGLETON_ID = "singleton"


async def _get_or_create_row(db) -> LlmNightBatchState:
    result = await db.execute(select(LlmNightBatchState).where(LlmNightBatchState.id == _SINGLETON_ID))
    row = result.scalar_one_or_none()
    if row is None:
        row = LlmNightBatchState(id=_SINGLETON_ID)
        db.add(row)
    return row


# pod_start 시점에 그날 밤 상태를 초기화. last_send_at을 지금 시각으로 잡아둬서, 보낼 게
# 하나도 없는 밤에도 이때부터 유휴 시간이 흐르기 시작해 안전망이 정상 동작한다
async def reset_llm_night_state() -> None:
    async with AsyncSessionLocal() as db:
        row = await _get_or_create_row(db)
        row.last_send_at = datetime.now(timezone.utc)
        row.last_callback_at = None
        row.early_stopped_at = None
        row.all_sent_at = None
        row.pending_count = 0
        await db.commit()


# 3개 야간 전송 배치(크롤링/아티스트추출/일기)가 실제로 뭔가 보냈을 때 호출 - count만큼 pending_count 증가
async def mark_llm_sent(count: int) -> None:
    if count <= 0:
        return
    async with AsyncSessionLocal() as db:
        row = await _get_or_create_row(db)
        row.last_send_at = datetime.now(timezone.utc)
        row.pending_count = (row.pending_count or 0) + count
        await db.commit()


# 그날 밤 전송 배치 3개(크롤링→아티스트추출→일기)가 전부 끝났을 때(diary_send 완료 시) 호출.
# 이게 찍혀야만 pending_count==0을 "완료"로 인정 - 안 찍혔으면 아직 안 보낸 배치가 남아있을 수 있음
async def mark_all_sent_for_tonight() -> None:
    async with AsyncSessionLocal() as db:
        row = await _get_or_create_row(db)
        row.all_sent_at = datetime.now(timezone.utc)
        await db.commit()


# LLM팀 웹훅 3개(crawl-result/artist-result/diary-result)가 콜백 받을 때마다 호출 - 유휴
# 판단 기준 시각 갱신 + pending_count 1 감소(0 밑으로는 안 내려가게 클램프, 중복 콜백 방어)
async def mark_llm_callback_received() -> None:
    async with AsyncSessionLocal() as db:
        row = await _get_or_create_row(db)
        row.last_callback_at = datetime.now(timezone.utc)
        row.pending_count = max(0, (row.pending_count or 0) - 1)
        await db.commit()


async def mark_stopped_early() -> None:
    async with AsyncSessionLocal() as db:
        row = await _get_or_create_row(db)
        row.early_stopped_at = datetime.now(timezone.utc)
        await db.commit()


# 정확한 건수 매칭: 그날 밤 전송이 다 끝났고(all_sent_at) 보낸 만큼 콜백도 다 왔으면
# (pending_count<=0) 완료로 본다. 오늘 밤 이미 조기 정지했으면 재트리거 방지
async def is_llm_batch_fully_done() -> bool:
    async with AsyncSessionLocal() as db:
        result = await db.execute(select(LlmNightBatchState).where(LlmNightBatchState.id == _SINGLETON_ID))
        row = result.scalar_one_or_none()

    if row is None or row.early_stopped_at is not None:
        return False
    return row.all_sent_at is not None and row.pending_count <= 0


# 마지막 전송/콜백 중 더 늦은 시각 기준 idle_minutes 이상 조용하면 "끝났다"고 판단 - 정확한
# 건수 매칭이 콜백 유실 등으로 끝까지 0에 도달 못 할 때의 안전망. 이미 조기 정지했으면 재트리거 방지
async def is_llm_batch_idle(idle_minutes: float = 5.0) -> bool:
    async with AsyncSessionLocal() as db:
        result = await db.execute(select(LlmNightBatchState).where(LlmNightBatchState.id == _SINGLETON_ID))
        row = result.scalar_one_or_none()

    if row is None or row.last_send_at is None or row.early_stopped_at is not None:
        return False

    last_activity = max(row.last_send_at, row.last_callback_at or row.last_send_at)
    idle_for = datetime.now(timezone.utc) - last_activity
    return idle_for >= timedelta(minutes=idle_minutes)


# 웹훅이 콜백을 받은 직후 호출 - 방금 그 콜백으로 완료 조건이 맞으면 유휴시간을 기다리지
# 않고 즉시 정지. stop_pod 확인 폴링이 최대 2분 걸리니 호출부는 항상 BackgroundTasks로 부를 것
async def try_stop_pod_if_done() -> None:
    if not await is_llm_batch_fully_done():
        return
    from app.services.runpod import stop_pod  # 순환 임포트 방지용 지연 임포트

    logger.info("그날 밤 전송건수=콜백건수 일치 확인 - 조기 정지 시도")
    if await stop_pod():
        await mark_stopped_early()
        logger.info("정확한 건수 매칭으로 pod 조기 정지 완료 (유휴시간 체크/01시·02시 안전망은 그대로 유지됨)")
