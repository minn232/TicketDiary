from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.user import User
from app.schemas.settings import FcmTokenUpdate, UserSettingsResponse, UserSettingsUpdate
from app.services import settings as settings_service

router = APIRouter()


# 유저 설정 조회
@router.get("", response_model=UserSettingsResponse)
async def get_settings(current_user: User = Depends(get_current_user)):
    return current_user


# 유저 설정 수정
@router.patch("", response_model=UserSettingsResponse)
async def update_settings(
    body: UserSettingsUpdate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await settings_service.update_user_settings(db, current_user, body)


# FCM 토큰 업데이트
@router.patch("/fcm-token", response_model=UserSettingsResponse)
async def update_fcm_token(
    body: FcmTokenUpdate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await settings_service.update_fcm_token(db, current_user, body.fcm_token)
