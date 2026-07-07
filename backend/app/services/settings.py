from sqlalchemy.ext.asyncio import AsyncSession

from app.models.user import User
from app.schemas.settings import UserSettingsUpdate


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
        user.notification_settings = body.notification_settings.model_dump(mode="json")
    await db.commit()
    await db.refresh(user)
    return user
