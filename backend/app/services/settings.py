from sqlalchemy import delete, select, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.notification import Notification, NotificationType
from app.models.ticket import Ticket
from app.models.user import User
from app.schemas.settings import UserSettingsUpdate
from app.services.notification import reschedule_user_ticketing_notifications
from app.services.ticket import schedule_tickets_notifications_bulk

# 알림 설정 키 -> 이미 예약된 알림을 취소할 때 지울 NotificationType 목록
_NOTIF_TYPES_BY_SETTING: dict[str, list[NotificationType]] = {
    "delivery": [NotificationType.DELIVERY_DAY],
    "day_before": [NotificationType.DAY_BEFORE],
    "concert_day": [NotificationType.CONCERT_DAY],
    "ticketing": [NotificationType.TICKETING_DAY],
    "new_concert": [NotificationType.NEW_CONCERT],
}


# FCM 토큰 업데이트. 같은 기기에서 계정을 바꾸면 이전 계정에도 같은 토큰이 남아 그 계정 알림이 지금
# 쓰는 사람 폰으로 갔음 - 이 토큰을 가진 다른 유저에게선 지움
async def update_fcm_token(db: AsyncSession, user: User, fcm_token: str) -> User:
    await db.execute(
        update(User).where(User.fcm_token == fcm_token, User.id != user.id).values(fcm_token=None)
    )
    user.fcm_token = fcm_token
    await db.commit()
    await db.refresh(user)
    return user


# 유저 설정 수정
async def update_user_settings(db: AsyncSession, user: User, body: UserSettingsUpdate) -> User:
    if body.show_predicted_setlist is not None:
        user.show_predicted_setlist = body.show_predicted_setlist

    if body.share_next_concert is not None:
        user.share_next_concert = body.share_next_concert

    if body.notification_settings is not None:
        old_settings = user.notification_settings or {}
        # 보낸 필드만 반영 (model_dump 그대로 대입하면 안 보낸 필드가 pydantic 기본값으로
        # 덮어써져서 기존에 꺼둔 다른 알림 설정이 조용히 리셋되는 문제가 있었음)
        partial = body.notification_settings.model_dump(mode="json", exclude_none=True)
        new_settings = {**old_settings, **partial}
        user.notification_settings = new_settings

        # 유저가 지금 막 끈 알림 유형은, 이미 예약돼있던 미발송 알림도 같이 취소.
        # 안 그러면 설정을 꺼도 그 전에 예약된 알림이 그대로 발송되어버림
        newly_disabled_types = [
            notif_type
            for key, notif_types in _NOTIF_TYPES_BY_SETTING.items()
            if old_settings.get(key, True) and not new_settings.get(key, True)
            for notif_type in notif_types
        ]
        if newly_disabled_types:
            await db.execute(
                delete(Notification).where(
                    Notification.user_id == user.id,
                    Notification.type.in_(newly_disabled_types),
                    Notification.is_sent == False,  # noqa: E712
                )
            )

        # 다시 켠 알림은 등록된 티켓/찜 기준으로 다시 예약함 - 안 하면 끈 동안 지워진 예약이 티켓을
        # 고치거나 크롤링이 다시 돌기 전까지 안 살아남
        newly_enabled = {
            key for key in _NOTIF_TYPES_BY_SETTING
            if not old_settings.get(key, True) and new_settings.get(key, True)
        }
        if newly_enabled & {"delivery", "day_before", "concert_day"}:
            await db.flush()
            tickets = (
                await db.execute(
                    select(Ticket)
                    .options(selectinload(Ticket.concert), selectinload(Ticket.user))
                    .where(Ticket.user_id == user.id)
                )
            ).scalars().all()
            await schedule_tickets_notifications_bulk(db, list(tickets))
        if "ticketing" in newly_enabled:
            await reschedule_user_ticketing_notifications(db, user)

    await db.commit()
    await db.refresh(user)
    return user
