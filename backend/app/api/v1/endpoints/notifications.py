from uuid import UUID

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.user import User
from app.schemas.notification import NotificationResponse
from app.services import notification as notification_service

router = APIRouter()


# 알림 목록 조회
@router.get("", response_model=list[NotificationResponse])
async def list_notifications(
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await notification_service.get_notifications(db, current_user.id)


# 알림 읽음 처리
@router.patch("/{notification_id}/read", response_model=NotificationResponse)
async def read_notification(
    notification_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await notification_service.mark_as_read(db, current_user.id, notification_id)


# 알림 삭제
@router.delete("/{notification_id}", status_code=204)
async def remove_notification(
    notification_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await notification_service.delete_notification(db, current_user.id, notification_id)
