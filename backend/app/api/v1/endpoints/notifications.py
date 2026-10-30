from uuid import UUID

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.user import User
from app.schemas.notification import NotificationResponse, ReadAllResponse, UnreadCountResponse
from app.services import notification as notification_service

router = APIRouter()


# 알림 목록 조회 (limit/offset은 선택 - 생략하면 기본 상한(200건) 적용)
@router.get("", response_model=list[NotificationResponse])
async def list_notifications(
    limit: int = Query(200, ge=1, le=200),
    offset: int = Query(0, ge=0),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await notification_service.get_notifications(db, current_user.id, limit=limit, offset=offset)


# 안 읽은 알림 수 (설정 메뉴 배지용)
@router.get("/unread-count", response_model=UnreadCountResponse)
async def unread_count(
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return UnreadCountResponse(count=await notification_service.count_unread(db, current_user.id))


# 알림 전부 읽음 처리 (알림함 "모두 읽음")
@router.patch("/read-all", response_model=ReadAllResponse)
async def read_all_notifications(
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return ReadAllResponse(updated=await notification_service.mark_all_as_read(db, current_user.id))


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
