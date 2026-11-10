import uuid
from sqlalchemy import Boolean, Column, ForeignKey, text
from sqlalchemy.dialects.postgresql import UUID, JSONB
from sqlalchemy.orm import relationship
from app.core.database import Base


# contents JSON 형식: [{"date": "2023-09-07", "time": null, "stage": "TOUCH", "event": "N.Flying 16:20 - 17:20 (60)"}, ...]
class TimeTable(Base):
    __tablename__ = "timetables"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    concert_id = Column(UUID(as_uuid=True), ForeignKey("concerts.id"), nullable=False, unique=True)
    contents = Column(JSONB, nullable=False, server_default=text("'[]'::jsonb"))
    # 관리자가 직접 만들거나 고친 시간표면 true - LLM 크롤링 콜백이 덮어쓰지 않음(출연진의 source="admin"과 같은 역할)
    admin_edited = Column(Boolean, nullable=False, server_default=text("false"))

    concert = relationship("Concert", back_populates="timetable")
