import uuid

from sqlalchemy import Column, ForeignKey, String
from sqlalchemy.dialects.postgresql import UUID, JSONB
from sqlalchemy.orm import relationship

from app.core.database import Base


# 공연장 좌석 배치도 (크롤링 결과로 채워짐, concert당 1개)
class VenueLayout(Base):
    __tablename__ = "venue_layouts"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    concert_id = Column(UUID(as_uuid=True), ForeignKey("concerts.id"), nullable=False, unique=True)
    image_url = Column(String, nullable=True)
    layout_data = Column(JSONB, nullable=True)

    concert = relationship("Concert", back_populates="venue_layout")
