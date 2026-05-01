import uuid
from sqlalchemy import Column, ForeignKey
from sqlalchemy.dialects.postgresql import UUID, JSONB
from sqlalchemy.orm import relationship
from app.core.database import Base


"""
contents JSON 형식: [{"time": "17:00", "description": "입장"}, ...]
"""
class TimeTable(Base):
    __tablename__ = "timetables"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    concert_id = Column(UUID(as_uuid=True), ForeignKey("concerts.id"), nullable=False, unique=True)
    contents = Column(JSONB, nullable=False, default=list)

    concert = relationship("Concert", back_populates="timetable")
