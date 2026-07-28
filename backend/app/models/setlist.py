import uuid

from sqlalchemy import Column, String, ForeignKey, Boolean, Date, UniqueConstraint, text
from sqlalchemy.dialects.postgresql import UUID, JSONB
from sqlalchemy.orm import relationship

from app.core.database import Base


class RealSetlist(Base):
    __tablename__ = "real_setlists"

    # concert_id 단독이 아니라 (concert_id, performance_date) 조합으로 유일 - 페스티벌/여러 날
    # 투어처럼 한 concert가 여러 날짜에 걸치면 날짜별로 실제 셋리스트가 다를 수 있어서
    __table_args__ = (UniqueConstraint("concert_id", "performance_date", name="uq_real_setlists_concert_date"),)

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    concert_id = Column(UUID(as_uuid=True), ForeignKey("concerts.id"), nullable=False)
    # 이 셋리스트가 적용되는 실제 공연 날짜 (concert.start_date~end_date 범위 내). 하루짜리
    # 공연이면 자동으로 concert.start_date로 채워짐(services/setlist.py의 resolve_performance_date)
    performance_date = Column(Date, nullable=False)
    setlistfm_id = Column(String, nullable=True)
    songs = Column(JSONB, nullable=False)
    is_user_edited = Column(Boolean, nullable=False, server_default=text("false"))
    edited_user_nickname = Column(String, nullable=True)

    concert = relationship("Concert", back_populates="real_setlists")


class PreSetlist(Base):
    __tablename__ = "pre_setlists"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    concert_id = Column(UUID(as_uuid=True), ForeignKey("concerts.id"), nullable=False, unique=True)
    setlistfm_id = Column(String, nullable=True)
    songs = Column(JSONB, nullable=False)
    is_user_edited = Column(Boolean, nullable=False, server_default=text("false"))
    edited_user_nickname = Column(String, nullable=True)

    concert = relationship("Concert", back_populates="pre_setlist")
