import uuid
import enum

from sqlalchemy import Column, String, DateTime, ForeignKey, Boolean, Enum as SAEnum, Index
from sqlalchemy.dialects.postgresql import UUID

from app.core.database import Base


class NotificationType(str, enum.Enum):
    DAY_BEFORE = "day_before"
    CONCERT_DAY = "concert_day"
    DELIVERY_DAY = "delivery_day"
    TICKETING_DAY = "ticketing_day"
    NEW_CONCERT = "new_concert"


class Notification(Base):
    __tablename__ = "notifications"

    # process_pending_notifications가 is_sent=False AND scheduled_at<=now로 매번 조회하는데,
    # 발송된 알림을 따로 삭제/보관하지 않아 테이블이 계속 커지므로 인덱스 없이는 매 스케줄러
    # 틱마다 전체 테이블 스캔이 됨. ticket_id/concert_id/type은 알림 재스케줄 시 delete()
    # 필터에 쓰이는 조합이라 함께 인덱스로 커버
    __table_args__ = (
        Index("ix_notifications_is_sent_scheduled_at", "is_sent", "scheduled_at"),
        Index("ix_notifications_ticket_id_type", "ticket_id", "type"),
        Index("ix_notifications_concert_id_type", "concert_id", "type"),
    )

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    ticket_id = Column(UUID(as_uuid=True), ForeignKey("tickets.id", ondelete="CASCADE"), nullable=True)
    concert_id = Column(UUID(as_uuid=True), ForeignKey("concerts.id", ondelete="SET NULL"), nullable=True)
    type = Column(SAEnum(NotificationType, values_callable=lambda x: [e.value for e in x]), nullable=False)
    title = Column(String, nullable=False)
    body = Column(String, nullable=False)
    is_sent = Column(Boolean, default=False)
    is_read = Column(Boolean, default=False)
    scheduled_at = Column(DateTime(timezone=True), nullable=False)
