from pydantic import BaseModel
from uuid import UUID
from datetime import datetime
from app.models.notification import NotificationType


class NotificationResponse(BaseModel):
    model_config = {"from_attributes": True}

    # 알림 조회 응답
    id: UUID
    user_id: UUID
    ticket_id: UUID | None
    type: NotificationType
    title: str
    body: str
    is_sent: bool
    scheduled_at: datetime
