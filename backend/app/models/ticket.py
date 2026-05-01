import uuid
import enum
from sqlalchemy import Column, String, DateTime, ForeignKey, Enum as SAEnum, Text, Integer, Boolean, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship
from app.core.database import Base


class TicketStatus(str, enum.Enum):
    BEFORE_DELIVERY = "before_delivery"
    BEFORE_CONCERT = "before_concert"
    AFTER_CONCERT = "after_concert"


class Ticket(Base):
    __tablename__ = "tickets"

    __table_args__ = (UniqueConstraint("user_id", "concert_id"),)

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=False, index=True)
    concert_id = Column(UUID(as_uuid=True), ForeignKey("concerts.id"), nullable=True, index=True)
    status = Column(SAEnum(TicketStatus, values_callable=lambda x: [e.value for e in x]), default=TicketStatus.BEFORE_DELIVERY)
    delivery_date = Column(DateTime(timezone=True), nullable=True)
    ticketing_site = Column(String, nullable=True)
    price = Column(Integer, nullable=True)
    seat_type = Column(String, nullable=True)
    ticket_image_url = Column(String, nullable=True)
    review = Column(Text, nullable=True)
    concert_photo_urls = Column(Text, nullable=True)
    is_first_day = Column(Boolean, nullable=True)
    is_last_day = Column(Boolean, nullable=True)

    concert = relationship("Concert", back_populates="tickets")
