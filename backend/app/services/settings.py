from sqlalchemy import delete
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.notification import Notification, NotificationType
from app.models.user import User
from app.schemas.settings import UserSettingsUpdate

# 알림 설정 키 -> 이미 예약된 알림을 취소할 때 지울 NotificationType 목록
_NOTIF_TYPES_BY_SETTING: dict[str, list[NotificationType]] = {
    "delivery": [NotificationType.DELIVERY_DAY],
    "before_concert": [NotificationType.DAY_BEFORE, NotificationType.CONCERT_DAY],
    "ticketing": [NotificationType.TICKETING_DAY],
    "new_concert": [NotificationType.NEW_CONCERT],
}


# FCM 토큰 업데이트
async def update_fcm_token(db: AsyncSession, user: User, fcm_token: str) -> User:
    user.fcm_token = fcm_token
    await db.commit()
    await db.refresh(user)
    return user


# 유저 설정 수정
async def update_user_settings(db: AsyncSession, user: User, body: UserSettingsUpdate) -> User:
    if body.show_predicted_setlist is not None:
        user.show_predicted_setlist = body.show_predicted_setlist

    if body.notification_settings is not None:
        old_settings = user.notification_settings or {}
        new_settings = body.notification_settings.model_dump(mode="json")
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

    await db.commit()
    await db.refresh(user)
    return user
