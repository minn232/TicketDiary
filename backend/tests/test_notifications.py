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
        f"<prfcast>테스트아티스트</prfcast>"
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
        f"<prfcast>테스트아티스트</prfcast>"
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


# 알림 설정을 끄면 이미 예약돼있던 미발송 알림도 취소되는지 테스트
# (꺼도 그 전에 예약된 알림이 그대로 발송되던 버그 회귀 방지)
@pytest.mark.asyncio
async def test_disabling_delivery_setting_cancels_pending_notification():
    concert_id = await _create_concert("PF_SCHED_TOGGLE_001", _make_future_xml("PF_SCHED_TOGGLE_001"))
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.post(
            "/api/v1/tickets",
            json={"concert_id": concert_id, "delivery_date": "2030-05-15T00:00:00Z"},
            headers=headers,
        )
        res = await ac.get("/api/v1/notifications", headers=headers)
    assert "delivery_day" in {n["type"] for n in res.json()}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        settings_res = await ac.patch(
            "/api/v1/settings",
            json={"notification_settings": {"delivery": False}},
            headers=headers,
        )
        res = await ac.get("/api/v1/notifications", headers=headers)

    assert settings_res.status_code == 200
    assert "delivery_day" not in {n["type"] for n in res.json()}


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


# notification_settings 반영 테스트

# delivery=False 시 배송 알림 미생성 테스트
@pytest.mark.asyncio
async def test_delivery_notification_skipped_when_setting_off():
    concert_id = await _create_concert("PF_NOTIF_DEL_OFF_001", _make_future_xml("PF_NOTIF_DEL_OFF_001"))
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/settings",
            json={"notification_settings": {"delivery": False, "day_before": True, "concert_day": True}},
            headers=headers,
        )
        await ac.post(
            "/api/v1/tickets",
            json={"concert_id": concert_id, "delivery_date": "2030-05-15"},
            headers=headers,
        )
        res = await ac.get("/api/v1/notifications", headers=headers)

    types = {n["type"] for n in res.json()}
    assert "delivery_day" not in types
    assert "day_before" in types
    assert "concert_day" in types


# day_before/concert_day=False 시 공연 전/당일 알림 미생성 테스트
@pytest.mark.asyncio
async def test_before_concert_notification_skipped_when_setting_off():
    concert_id = await _create_concert("PF_NOTIF_BEFORE_OFF_001", _make_future_xml("PF_NOTIF_BEFORE_OFF_001"))
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/settings",
            json={"notification_settings": {"delivery": True, "day_before": False, "concert_day": False}},
            headers=headers,
        )
        await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)
        res = await ac.get("/api/v1/notifications", headers=headers)

    assert res.json() == []


# day_before만 False일 때 당일 알림만 생성되는 테스트
@pytest.mark.asyncio
async def test_day_before_off_concert_day_on_only_generates_concert_day():
    concert_id = await _create_concert("PF_NOTIF_DAYBEFORE_OFF_001", _make_future_xml("PF_NOTIF_DAYBEFORE_OFF_001"))
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/settings",
            json={"notification_settings": {"day_before": False, "concert_day": True}},
            headers=headers,
        )
        await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)
        res = await ac.get("/api/v1/notifications", headers=headers)

    types = {n["type"] for n in res.json()}
    assert "day_before" not in types
    assert "concert_day" in types


# 모든 알림 off 시 알림 미생성 테스트
@pytest.mark.asyncio
async def test_all_notifications_skipped_when_all_settings_off():
    concert_id = await _create_concert("PF_NOTIF_ALL_OFF_001", _make_future_xml("PF_NOTIF_ALL_OFF_001"))
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/settings",
            json={"notification_settings": {"delivery": False, "day_before": False, "concert_day": False}},
            headers=headers,
        )
        await ac.post(
            "/api/v1/tickets",
            json={"concert_id": concert_id, "delivery_date": "2030-05-15"},
            headers=headers,
        )
        res = await ac.get("/api/v1/notifications", headers=headers)

    assert res.json() == []


# 설정 변경 후 티켓 수정 시 재스케줄 반영 테스트
@pytest.mark.asyncio
async def test_notification_reschedule_respects_updated_settings():
    concert_id = await _create_concert("PF_NOTIF_RESCHED_001", _make_future_xml("PF_NOTIF_RESCHED_001"))
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        create_res = await ac.post("/api/v1/tickets", json={"concert_id": concert_id}, headers=headers)
        ticket_id = create_res.json()["id"]

        # 알림 생성 확인
        res_before = await ac.get("/api/v1/notifications", headers=headers)
        assert len(res_before.json()) >= 2

        # day_before/concert_day off로 변경 후 티켓 수정 (재스케줄 트리거)
        await ac.patch(
            "/api/v1/settings",
            json={"notification_settings": {"delivery": True, "day_before": False, "concert_day": False}},
            headers=headers,
        )
        await ac.patch(f"/api/v1/tickets/{ticket_id}", json={"seat_type": "VIP"}, headers=headers)
        res_after = await ac.get("/api/v1/notifications", headers=headers)

    assert res_after.json() == []


# ticketing_day 알림 테스트

_LLM_API_KEY = "test-llm-key"


def _llm_headers():
    return {"Authorization": f"Bearer {_LLM_API_KEY}"}


# 찜 공연에 ticketing_date 수신 → 팔로워에게 TICKETING_DAY 알림 생성
@pytest.mark.asyncio
async def test_ticketing_day_notification_for_concert_follower():
    concert_id = await _create_concert("PF_TICK_NOTIF_001", _make_future_xml("PF_TICK_NOTIF_001"))
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    # 공연 찜
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/concerts",
            json={"concerts": [{"concert_id": concert_id}]},
            headers=headers,
        )

    # ticketing_date 수신
    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json={"ticketing_date": "2030-04-15"},
                headers=_llm_headers(),
            )

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/notifications", headers=headers)

    types = {n["type"] for n in res.json()}
    assert "ticketing_day" in types


# 찜 안 한 유저에게는 TICKETING_DAY 알림 미생성
@pytest.mark.asyncio
async def test_ticketing_day_notification_not_for_non_follower():
    concert_id = await _create_concert("PF_TICK_NOTIF_002", _make_future_xml("PF_TICK_NOTIF_002"))
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    # 찜 안 함 (concert_follow 미설정)

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json={"ticketing_date": "2030-04-15"},
                headers=_llm_headers(),
            )

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/notifications", headers=headers)

    types = {n["type"] for n in res.json()}
    assert "ticketing_day" not in types


# 이미 지난 ticketing_date → 알림 미생성
@pytest.mark.asyncio
async def test_ticketing_day_notification_past_date_skipped():
    concert_id = await _create_concert("PF_TICK_NOTIF_003", _make_future_xml("PF_TICK_NOTIF_003"))
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/concerts",
            json={"concerts": [{"concert_id": concert_id}]},
            headers=headers,
        )

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json={"ticketing_date": "2000-01-01"},  # 과거 날짜
                headers=_llm_headers(),
            )

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/notifications", headers=headers)

    types = {n["type"] for n in res.json()}
    assert "ticketing_day" not in types


# ticketing_date 두 번 수신 → 알림 중복 없음 (이전 미발송 삭제 후 재생성)
@pytest.mark.asyncio
async def test_ticketing_day_notification_no_duplicate_on_resend():
    concert_id = await _create_concert("PF_TICK_NOTIF_004", _make_future_xml("PF_TICK_NOTIF_004"))
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/concerts",
            json={"concerts": [{"concert_id": concert_id}]},
            headers=headers,
        )

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json={"ticketing_date": "2030-04-15"},
                headers=_llm_headers(),
            )
            await ac.post(
                f"/api/v1/concerts/{concert_id}/crawl-result",
                json={"ticketing_date": "2030-04-20"},  # 날짜 변경 재전송
                headers=_llm_headers(),
            )

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/notifications", headers=headers)

    ticketing_notifs = [n for n in res.json() if n["type"] == "ticketing_day"]
    assert len(ticketing_notifs) == 1  # 중복 없이 최신 날짜 1개만
