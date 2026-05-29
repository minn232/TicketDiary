import uuid
import pytest
from datetime import datetime, timezone, timedelta
from unittest.mock import patch
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select, update

from app.main import app
from app.core.database import AsyncSessionLocal
from app.models.notification import Notification
from app.models.user import User
from app.services.notification import process_pending_notifications
from conftest import _get_token, kopis_mock


# 헬퍼

# 미래 공연 KOPIS XML 생성 (티켓 등록 시 알림 자동 생성용)
def _make_future_xml(kopis_id: str) -> bytes:
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f"<dbs><db>"
        f"<mt20id>{kopis_id}</mt20id>"
        f"<prfnm>{kopis_id} 공연</prfnm>"
        f"<prfpdfrom>2030.06.01</prfpdfrom>"
        f"<prfpdto>2030.06.30</prfpdto>"
        f"<fcltynm>테스트공연장</fcltynm>"
        f"<genrenm>팝</genrenm>"
        f"<prfcrew>출연: 테스트아티스트</prfcrew>"
        f"<pcseguidance></pcseguidance>"
        f"<sty></sty>"
        f"</db></dbs>"
    ).encode("utf-8")


# 과거 공연 KOPIS XML 생성 (알림 미생성 검증용)
def _make_past_xml(kopis_id: str) -> bytes:
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f"<dbs><db>"
        f"<mt20id>{kopis_id}</mt20id>"
        f"<prfnm>{kopis_id} 공연</prfnm>"
        f"<prfpdfrom>2000.01.01</prfpdfrom>"
        f"<prfpdto>2000.01.01</prfpdto>"
        f"<fcltynm>테스트공연장</fcltynm>"
        f"<genrenm>팝</genrenm>"
        f"<prfcrew>출연: 테스트아티스트</prfcrew>"
        f"<pcseguidance></pcseguidance>"
        f"<sty></sty>"
        f"</db></dbs>"
    ).encode("utf-8")


# KOPIS mock으로 공연 생성 후 concert_id 반환
async def _create_concert(kopis_id: str, xml: bytes) -> str:
    token = await _get_token()
    with kopis_mock(xml):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.get(
                f"/api/v1/concerts/{kopis_id}",
                headers={"Authorization": f"Bearer {token}"},
            )
    assert res.status_code == 200
    return res.json()["id"]


# 티켓 등록 후 ticket_id 반환
async def _create_ticket(concert_id: str, token: str) -> str:
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.post(
            "/api/v1/tickets",
            json={"concert_id": concert_id},
            headers={"Authorization": f"Bearer {token}"},
        )
    assert res.status_code == 201
    return res.json()["id"]


# 토큰으로 유저 ID 조회
async def _get_user_id(token: str) -> str:
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/auth/me", headers={"Authorization": f"Bearer {token}"})
    return res.json()["id"]


# 해당 유저의 첫 번째 알림 ID 조회 (목록 최신순 기준)
async def _get_first_notification_id(token: str) -> str:
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/notifications", headers={"Authorization": f"Bearer {token}"})
    notifications = res.json()
    assert len(notifications) > 0
    return notifications[0]["id"]


# 알림 목록 조회 테스트

# 알림이 없을 때 빈 배열 반환 테스트
@pytest.mark.asyncio
async def test_list_notifications_empty():
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/notifications", headers={"Authorization": f"Bearer {token}"})

    assert res.status_code == 200
    assert res.json() == []


# 미래 공연 티켓 등록 시 알림 자동 생성 테스트 (day_before + concert_day)
@pytest.mark.asyncio
async def test_list_notifications_created_by_ticket():
    concert_id = await _create_concert("PF_NOTIF_LIST_001", _make_future_xml("PF_NOTIF_LIST_001"))
    token = await _get_token()
    await _create_ticket(concert_id, token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/notifications", headers={"Authorization": f"Bearer {token}"})

    assert res.status_code == 200
    notifications = res.json()
    assert len(notifications) >= 2
    types = {n["type"] for n in notifications}
    assert "day_before" in types
    assert "concert_day" in types


# 다른 유저의 알림이 조회되지 않는 격리 테스트
@pytest.mark.asyncio
async def test_list_notifications_user_isolation():
    concert_id = await _create_concert("PF_NOTIF_ISO_001", _make_future_xml("PF_NOTIF_ISO_001"))
    token_a = await _get_token()
    token_b = await _get_token()
    await _create_ticket(concert_id, token_a)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/notifications", headers={"Authorization": f"Bearer {token_b}"})

    assert res.status_code == 200
    assert res.json() == []


# 미인증 요청 401 테스트
@pytest.mark.asyncio
async def test_list_notifications_no_auth_401():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/notifications")

    assert res.status_code == 401


# 알림 읽음 처리 테스트

# 읽음 처리 성공 (is_read=True) 테스트
@pytest.mark.asyncio
async def test_mark_notification_as_read_success():
    concert_id = await _create_concert("PF_NOTIF_READ_001", _make_future_xml("PF_NOTIF_READ_001"))
    token = await _get_token()
    await _create_ticket(concert_id, token)
    notification_id = await _get_first_notification_id(token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.patch(
            f"/api/v1/notifications/{notification_id}/read",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert res.status_code == 200
    assert res.json()["is_read"] is True
    assert res.json()["id"] == notification_id


# 존재하지 않는 알림 읽음 처리 404 테스트
@pytest.mark.asyncio
async def test_mark_notification_as_read_not_found_404():
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.patch(
            f"/api/v1/notifications/{uuid.uuid4()}/read",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert res.status_code == 404


# 다른 유저의 알림 읽음 처리 404 테스트
@pytest.mark.asyncio
async def test_mark_notification_other_user_404():
    concert_id = await _create_concert("PF_NOTIF_READ_OTHER_001", _make_future_xml("PF_NOTIF_READ_OTHER_001"))
    token_a = await _get_token()
    token_b = await _get_token()
    await _create_ticket(concert_id, token_a)
    notification_id = await _get_first_notification_id(token_a)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.patch(
            f"/api/v1/notifications/{notification_id}/read",
            headers={"Authorization": f"Bearer {token_b}"},
        )

    assert res.status_code == 404


# 알림 삭제 테스트

# 삭제 성공 후 목록에서 사라지는 테스트
@pytest.mark.asyncio
async def test_delete_notification_success():
    concert_id = await _create_concert("PF_NOTIF_DEL_001", _make_future_xml("PF_NOTIF_DEL_001"))
    token = await _get_token()
    await _create_ticket(concert_id, token)
    notification_id = await _get_first_notification_id(token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        del_res = await ac.delete(
            f"/api/v1/notifications/{notification_id}",
            headers={"Authorization": f"Bearer {token}"},
        )
        list_res = await ac.get("/api/v1/notifications", headers={"Authorization": f"Bearer {token}"})

    assert del_res.status_code == 204
    ids = [n["id"] for n in list_res.json()]
    assert notification_id not in ids


# 존재하지 않는 알림 삭제 404 테스트
@pytest.mark.asyncio
async def test_delete_notification_not_found_404():
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.delete(
            f"/api/v1/notifications/{uuid.uuid4()}",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert res.status_code == 404


# 다른 유저의 알림 삭제 404 테스트
@pytest.mark.asyncio
async def test_delete_notification_other_user_404():
    concert_id = await _create_concert("PF_NOTIF_DEL_OTHER_001", _make_future_xml("PF_NOTIF_DEL_OTHER_001"))
    token_a = await _get_token()
    token_b = await _get_token()
    await _create_ticket(concert_id, token_a)
    notification_id = await _get_first_notification_id(token_a)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.delete(
            f"/api/v1/notifications/{notification_id}",
            headers={"Authorization": f"Bearer {token_b}"},
        )

    assert res.status_code == 404


# schedule_ticket_notifications 단위 테스트

# 미래 공연 티켓 등록 시 day_before + concert_day 알림 생성 테스트
@pytest.mark.asyncio
async def test_schedule_creates_notifications_for_future_concert():
    concert_id = await _create_concert("PF_SCHED_FUTURE_001", _make_future_xml("PF_SCHED_FUTURE_001"))
    token = await _get_token()
    await _create_ticket(concert_id, token)
    user_id = uuid.UUID(await _get_user_id(token))

    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(Notification).where(Notification.user_id == user_id)
        )
        notifications = result.scalars().all()

    types = {n.type.value for n in notifications}
    assert "day_before" in types
    assert "concert_day" in types
    assert all(n.is_sent is False for n in notifications)


# 과거 공연 티켓 등록 시 알림 미생성 테스트
@pytest.mark.asyncio
async def test_schedule_creates_no_notifications_for_past_concert():
    concert_id = await _create_concert("PF_SCHED_PAST_001", _make_past_xml("PF_SCHED_PAST_001"))
    token = await _get_token()
    await _create_ticket(concert_id, token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/notifications", headers={"Authorization": f"Bearer {token}"})

    assert res.status_code == 200
    assert res.json() == []


# 티켓 수정 시 기존 미발송 알림 초기화 후 재등록 테스트
@pytest.mark.asyncio
async def test_schedule_resets_on_ticket_update():
    concert_id = await _create_concert("PF_SCHED_RESET_001", _make_future_xml("PF_SCHED_RESET_001"))
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}
    ticket_id = await _create_ticket(concert_id, token)

    # 배송일 추가 수정 -> delivery_day 알림 추가 생성 확인
    delivery_date = "2030-05-15"
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            f"/api/v1/tickets/{ticket_id}",
            json={"delivery_date": delivery_date},
            headers=headers,
        )
        res = await ac.get("/api/v1/notifications", headers=headers)

    types = {n["type"] for n in res.json()}
    assert "delivery_day" in types


# process_pending_notifications 단위 테스트

# 기한 도래 + fcm_token 있는 미발송 알림 -> FCM 발송 및 is_sent=True 테스트
@pytest.mark.asyncio
async def test_process_pending_notifications_sends_fcm():
    concert_id = await _create_concert("PF_PROC_FCM_001", _make_future_xml("PF_PROC_FCM_001"))
    token = await _get_token()
    await _create_ticket(concert_id, token)
    user_id = uuid.UUID(await _get_user_id(token))

    async with AsyncSessionLocal() as db:
        # fcm_token 설정 및 알림 scheduled_at을 과거로 변경
        await db.execute(update(User).where(User.id == user_id).values(fcm_token="test-fcm-token"))
        await db.execute(
            update(Notification)
            .where(Notification.user_id == user_id)
            .values(scheduled_at=datetime.now(timezone.utc) - timedelta(minutes=5))
        )
        await db.commit()

    with patch("app.services.notification._send_fcm", return_value=True) as mock_send:
        async with AsyncSessionLocal() as db:
            await process_pending_notifications(db)

    assert mock_send.called

    # is_sent=True로 변경됐는지 DB에서 직접 확인
    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(Notification).where(Notification.user_id == user_id)
        )
        notifications = result.scalars().all()

    assert all(n.is_sent is True for n in notifications)


# fcm_token 없는 유저의 알림 -> 발송 스킵 테스트
@pytest.mark.asyncio
async def test_process_pending_notifications_skips_no_token():
    concert_id = await _create_concert("PF_PROC_NOFCM_001", _make_future_xml("PF_PROC_NOFCM_001"))
    token = await _get_token()
    await _create_ticket(concert_id, token)
    user_id = uuid.UUID(await _get_user_id(token))

    async with AsyncSessionLocal() as db:
        # fcm_token 없는 상태로 scheduled_at만 과거로 변경
        await db.execute(
            update(Notification)
            .where(Notification.user_id == user_id)
            .values(scheduled_at=datetime.now(timezone.utc) - timedelta(minutes=5))
        )
        await db.commit()

    with patch("app.services.notification._send_fcm", return_value=True) as mock_send:
        async with AsyncSessionLocal() as db:
            await process_pending_notifications(db)

    assert not mock_send.called


# 미래 예약 알림 -> 기한 미도래로 발송 안 됨 테스트
@pytest.mark.asyncio
async def test_process_pending_notifications_skips_future_scheduled():
    concert_id = await _create_concert("PF_PROC_FUTURE_001", _make_future_xml("PF_PROC_FUTURE_001"))
    token = await _get_token()
    await _create_ticket(concert_id, token)
    user_id = uuid.UUID(await _get_user_id(token))

    async with AsyncSessionLocal() as db:
        # fcm_token 설정 (scheduled_at은 미래 그대로 유지)
        await db.execute(update(User).where(User.id == user_id).values(fcm_token="test-fcm-token"))
        await db.commit()

    with patch("app.services.notification._send_fcm", return_value=True) as mock_send:
        async with AsyncSessionLocal() as db:
            await process_pending_notifications(db)

    assert not mock_send.called
