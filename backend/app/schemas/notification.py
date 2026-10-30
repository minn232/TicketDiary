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
    # 알림이 가리키는 공연(눌렀을 때 이동·포스터 썸네일용) - 티켓 알림(배송/전날/당일)은 저장된
    # concert_id가 없어서 목록 조회 때 티켓을 통해 채움. 다른 응답엔 저장된 값만 들어감
    concert_id: UUID | None = None
    poster_url: str | None = None


class UnreadCountResponse(BaseModel):
    # 안 읽은(발송된) 알림 수 - 설정 메뉴 배지용
    count: int


class ReadAllResponse(BaseModel):
    # 이번에 읽음으로 바뀐 알림 수
    updated: int
