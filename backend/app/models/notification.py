import uuid
import enum

from sqlalchemy import Column, String, DateTime, ForeignKey, Boolean, Enum as SAEnum
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
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=False, index=True)
    ticket_id = Column(UUID(as_uuid=True), ForeignKey("tickets.id", ondelete="CASCADE"), nullable=True)
    type = Column(SAEnum(NotificationType, values_callable=lambda x: [e.value for e in x]), nullable=False)
    title = Column(String, nullable=False)
    body = Column(String, nullable=False)
    is_sent = Column(Boolean, default=False)
    is_read = Column(Boolean, default=False)
    scheduled_at = Column(DateTime(timezone=True), nullable=False)
