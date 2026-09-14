from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock, patch

import pytest
from sqlalchemy import select

from app.core.database import AsyncSessionLocal
from app.models.llm_batch_state import LlmNightBatchState
from app.services.llm_batch_state import (
    is_llm_batch_fully_done,
    is_llm_batch_idle,
    mark_all_sent_for_tonight,
    mark_llm_callback_received,
    mark_llm_sent,
    mark_stopped_early,
    reset_llm_night_state,
    try_stop_pod_if_done,
)


async def _get_row() -> LlmNightBatchState:
    async with AsyncSessionLocal() as db:
        result = await db.execute(select(LlmNightBatchState).where(LlmNightBatchState.id == "singleton"))
        return result.scalar_one_or_none()


async def _set_row(*, last_send_at=None, last_callback_at=None, early_stopped_at=None,
                    all_sent_at=None, pending_count=0) -> None:
    async with AsyncSessionLocal() as db:
        result = await db.execute(select(LlmNightBatchState).where(LlmNightBatchState.id == "singleton"))
        row = result.scalar_one_or_none()
        if row is None:
            row = LlmNightBatchState(id="singleton")
            db.add(row)
        row.last_send_at = last_send_at
        row.last_callback_at = last_callback_at
        row.early_stopped_at = early_stopped_at
        row.all_sent_at = all_sent_at
        row.pending_count = pending_count
        await db.commit()


# ---- 유휴시간 방식 (안전망) ----

# 아직 아무 활동도 없으면(row 없음) 유휴 판단 근거가 없어 False
@pytest.mark.asyncio
async def test_is_idle_false_when_never_started():
    await _set_row()  # row는 만들지만 전부 기본값
    assert await is_llm_batch_idle(idle_minutes=5.0) is False


# pod_start가 초기화하면 last_send_at이 지금 시각으로 찍혀서, 그 시점부터 유휴 시간이 흐름
@pytest.mark.asyncio
async def test_reset_sets_last_send_at_to_now_and_clears_counters():
    await reset_llm_night_state()
    row = await _get_row()
    assert row.last_send_at is not None
    assert row.last_callback_at is None
    assert row.early_stopped_at is None
    assert row.all_sent_at is None
    assert row.pending_count == 0
    # 방금 초기화했으니 5분 유휴 기준으로는 아직 유휴가 아님
    assert await is_llm_batch_idle(idle_minutes=5.0) is False


# 마지막 전송이 5분보다 오래 전이고 콜백도 없으면 유휴로 판단
@pytest.mark.asyncio
async def test_is_idle_true_after_threshold_with_no_callback():
    old = datetime.now(timezone.utc) - timedelta(minutes=10)
    await _set_row(last_send_at=old)
    assert await is_llm_batch_idle(idle_minutes=5.0) is True
    assert await is_llm_batch_idle(idle_minutes=15.0) is False


# 전송은 오래 전이었어도 콜백이 최근에 왔으면(pod이 아직 처리 중) 유휴가 아님
@pytest.mark.asyncio
async def test_is_idle_false_when_recent_callback():
    old_send = datetime.now(timezone.utc) - timedelta(minutes=20)
    recent_callback = datetime.now(timezone.utc) - timedelta(minutes=1)
    await _set_row(last_send_at=old_send, last_callback_at=recent_callback)
    assert await is_llm_batch_idle(idle_minutes=5.0) is False


# 오늘 밤 이미 조기 정지했으면(early_stopped_at) 계속 유휴 조건이 참이어도 다시 트리거하지 않음
@pytest.mark.asyncio
async def test_is_idle_false_once_already_stopped_early():
    old = datetime.now(timezone.utc) - timedelta(minutes=10)
    await _set_row(last_send_at=old)
    await mark_stopped_early()
    assert await is_llm_batch_idle(idle_minutes=5.0) is False


# ---- 정확한 건수 매칭 ----

# mark_llm_sent(count)가 pending_count를 누적하는지 확인 (0건 전송은 무시)
@pytest.mark.asyncio
async def test_mark_llm_sent_accumulates_pending_count():
    await reset_llm_night_state()
    await mark_llm_sent(3)
    await mark_llm_sent(2)
    row = await _get_row()
    assert row.pending_count == 5

    await mark_llm_sent(0)  # 0건은 무시(누적 안 됨)
    row = await _get_row()
    assert row.pending_count == 5


# mark_llm_callback_received가 pending_count를 하나씩 줄이고, 0 밑으로는 안 내려감(중복 콜백 방어)
@pytest.mark.asyncio
async def test_mark_llm_callback_received_decrements_and_clamps_at_zero():
    await reset_llm_night_state()
    await mark_llm_sent(1)
    await mark_llm_callback_received()
    row = await _get_row()
    assert row.pending_count == 0

    await mark_llm_callback_received()  # 중복 콜백
    row = await _get_row()
    assert row.pending_count == 0


# all_sent_at이 없으면(아직 그날 밤 전송이 안 끝났으면) pending_count가 우연히 0이어도 완료로 안 봄
@pytest.mark.asyncio
async def test_fully_done_false_before_all_sent_marked():
    await reset_llm_night_state()
    await mark_llm_sent(1)
    await mark_llm_callback_received()
    assert (await _get_row()).pending_count == 0
    assert await is_llm_batch_fully_done() is False


# all_sent_at도 찍히고 pending_count도 0이면 완료로 판단
@pytest.mark.asyncio
async def test_fully_done_true_after_all_sent_and_count_zero():
    await reset_llm_night_state()
    await mark_llm_sent(2)
    await mark_llm_callback_received()
    await mark_llm_callback_received()
    await mark_all_sent_for_tonight()
    assert await is_llm_batch_fully_done() is True


# all_sent_at은 찍혔지만 아직 콜백이 덜 왔으면(pending_count>0) 완료 아님
@pytest.mark.asyncio
async def test_fully_done_false_when_callbacks_still_pending():
    await reset_llm_night_state()
    await mark_llm_sent(2)
    await mark_llm_callback_received()  # 1건만 콜백 옴
    await mark_all_sent_for_tonight()
    assert await is_llm_batch_fully_done() is False


# 이미 조기 정지했으면(early_stopped_at) 건수가 다시 맞아도 완료로 재판단하지 않음
@pytest.mark.asyncio
async def test_fully_done_false_once_already_stopped_early():
    await reset_llm_night_state()
    await mark_llm_sent(1)
    await mark_llm_callback_received()
    await mark_all_sent_for_tonight()
    await mark_stopped_early()
    assert await is_llm_batch_fully_done() is False


# try_stop_pod_if_done: 아직 완료가 아니면 stop_pod을 호출하지 않음
@pytest.mark.asyncio
async def test_try_stop_pod_if_done_noop_when_not_done():
    await reset_llm_night_state()
    await mark_llm_sent(2)
    await mark_llm_callback_received()  # 1건만 콜백 옴, all_sent도 안 찍힘
    with patch("app.services.runpod.stop_pod", new=AsyncMock(return_value=True)) as mock_stop:
        await try_stop_pod_if_done()
    assert not mock_stop.called


# try_stop_pod_if_done: 완료 조건이 맞으면 stop_pod을 호출하고, 실제 정지 확인되면 early_stopped_at을 찍음
@pytest.mark.asyncio
async def test_try_stop_pod_if_done_stops_and_marks_when_confirmed():
    await reset_llm_night_state()
    await mark_llm_sent(1)
    await mark_llm_callback_received()
    await mark_all_sent_for_tonight()

    with patch("app.services.runpod.stop_pod", new=AsyncMock(return_value=True)) as mock_stop:
        await try_stop_pod_if_done()
    assert mock_stop.called
    row = await _get_row()
    assert row.early_stopped_at is not None


# try_stop_pod_if_done: stop_pod이 실제 정지를 확인 못 하면(False) early_stopped_at을 찍지 않음 -
# 다음 콜백/유휴체크 tick에서 다시 시도할 수 있게 남겨둠
@pytest.mark.asyncio
async def test_try_stop_pod_if_done_does_not_mark_when_stop_unconfirmed():
    await reset_llm_night_state()
    await mark_llm_sent(1)
    await mark_llm_callback_received()
    await mark_all_sent_for_tonight()

    with patch("app.services.runpod.stop_pod", new=AsyncMock(return_value=False)):
        await try_stop_pod_if_done()
    row = await _get_row()
    assert row.early_stopped_at is None
