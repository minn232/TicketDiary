from pydantic import BaseModel
from uuid import UUID
from datetime import datetime
from app.models.notification import NotificationType


class NotificationResponse(BaseModel):
    # 알림 조회 응답
    model_config = {"from_attributes": True}

    id: UUID
    user_id: UUID
    ticket_id: UUID | None
    type: NotificationType
    title: str
    body: str
    is_sent: bool
    is_read: bool
    scheduled_at: datetime
