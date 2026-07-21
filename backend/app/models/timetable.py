import uuid
from sqlalchemy import Column, ForeignKey, text
from sqlalchemy.dialects.postgresql import UUID, JSONB
from sqlalchemy.orm import relationship
from app.core.database import Base


"""
contents JSON 형식: [{"date": "2023-09-07", "time": null, "stage": "TOUCH", "event": "N.Flying 16:20 - 17:20 (60)"}, ...]
"""
class TimeTable(Base):
    __tablename__ = "timetables"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    concert_id = Column(UUID(as_uuid=True), ForeignKey("concerts.id"), nullable=False, unique=True)
    contents = Column(JSONB, nullable=False, server_default=text("'[]'::jsonb"))

    concert = relationship("Concert", back_populates="timetable")
