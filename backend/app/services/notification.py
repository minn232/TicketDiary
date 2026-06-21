import asyncio
import logging
from uuid import UUID
from datetime import datetime, timezone

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.models.notification import Notification
from app.models.user import User

logger = logging.getLogger(__name__)

_firebase_initialized = False


# Firebase 초기화
def _init_firebase() -> None:
    global _firebase_initialized
    if _firebase_initialized:
        return
    try:
        import firebase_admin
        from firebase_admin import credentials
        if not firebase_admin._apps:
            cred = credentials.Certificate(settings.FIREBASE_CREDENTIALS_PATH)
            firebase_admin.initialize_app(cred)
        _firebase_initialized = True
    except Exception as e:
        logger.error(f"Firebase 초기화 실패: {e}")


# 알림 목록 조회
async def get_notifications(db: AsyncSession, user_id: UUID) -> list[Notification]:
    result = await db.execute(
        select(Notification)
        .where(Notification.user_id == user_id)
        .order_by(Notification.scheduled_at.desc())
    )
    return list(result.scalars().all())


# 알림 읽음 처리
async def mark_as_read(db: AsyncSession, user_id: UUID, notification_id: UUID) -> Notification:
    result = await db.execute(
        select(Notification).where(
            Notification.id == notification_id,
            Notification.user_id == user_id,
        )
    )
    notif = result.scalar_one_or_none()
    if notif is None:
        raise HTTPException(status_code=404, detail="알림을 찾을 수 없습니다.")
    notif.is_read = True
    await db.commit()
    return notif


# 알림 삭제
async def delete_notification(db: AsyncSession, user_id: UUID, notification_id: UUID) -> None:
    result = await db.execute(
        select(Notification).where(
            Notification.id == notification_id,
            Notification.user_id == user_id,
        )
    )
    notif = result.scalar_one_or_none()
    if notif is None:
        raise HTTPException(status_code=404, detail="알림을 찾을 수 없습니다.")
    await db.delete(notif)
    await db.commit()


# FCM 푸시 발송
def _send_fcm(token: str, title: str, body: str) -> bool:
    try:
        _init_firebase()
        from firebase_admin import messaging
        message = messaging.Message(
            notification=messaging.Notification(title=title, body=body),
            token=token,
        )
        messaging.send(message)
        return True
    except Exception as e:
        logger.error(f"FCM 발송 실패: {e}")
        return False


# 미발송 알림 처리 및 FCM 발송 (스케줄러 호출용)
async def process_pending_notifications(db: AsyncSession) -> None:
    # 현재 시각 기준으로 발송되지 않은 알림 조회
    now = datetime.now(timezone.utc)

    result = await db.execute(
        select(Notification, User.fcm_token)
        .join(User, Notification.user_id == User.id)
        .where(
            Notification.is_sent == False,  # noqa: E712
            Notification.scheduled_at <= now,
            User.fcm_token.isnot(None),
        )
    )
    rows = result.all()

    # 각 알림에 대해 FCM 발송 시도 -> 성공 시 is_sent=True
    loop = asyncio.get_event_loop()
    for notif, fcm_token in rows:
        success = await loop.run_in_executor(None, _send_fcm, fcm_token, notif.title, notif.body)
        if success:
            notif.is_sent = True

    if rows:
        await db.commit()
