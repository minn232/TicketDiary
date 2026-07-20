import uuid
import enum

from sqlalchemy import Column, String, DateTime, Text
from sqlalchemy.dialects.postgresql import UUID, ARRAY, JSONB
from sqlalchemy.orm import relationship

from app.core.database import Base


# 공연 유형 (단독 공연 / 페스티벌 / 미분류)
class EventType(str, enum.Enum):
    SOLO = "SOLO"
    FESTIVAL = "FESTIVAL"
    UNKNOWN = "UNKNOWN"


# price JSON 형식: [{"seat_type": "S석", "price": 10000}]
class Concert(Base):
    __tablename__ = "concerts"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    kopis_id = Column(String, nullable=True, index=True)
    name = Column(String, nullable=False)
    artist_name = Column(ARRAY(String), nullable=False)
    venue = Column(String, nullable=True)
    start_date = Column(DateTime(timezone=True), nullable=False)
    end_date = Column(DateTime(timezone=True), nullable=False)
    # KOPIS dtguidance 파싱 결과 ("HH:MM"). 요일/회차별로 시간이 여러 개면 대표값을 정할 수 없으므로 None
    start_time = Column(String, nullable=True)
    genre = Column(ARRAY(String), nullable=True)
    poster_url = Column(String, nullable=True)
    description = Column(Text, nullable=True)
    price = Column(JSONB, nullable=True)
    event_type = Column(String, nullable=False, default=EventType.UNKNOWN.value)
    crawl_screenshot_url = Column(String, nullable=True)
    ticketing_date = Column(DateTime(timezone=True), nullable=True)
    ticketing_links = Column(JSONB, nullable=True)
    # KOPIS 상세 API(/pblprfr/{id})로 아티스트/가격 등을 채운 시점. 검색(목록 API) 경유로만
    # 생성된 공연은 이 값이 None이라 artist_name이 비어 있어도 "진짜 출연진 없음"과 구분 못하므로,
    # 상세 조회 시 이 값 유무로 재조회 필요 여부를 판단함 (None이면 아직 상세 미조회)
    kopis_detail_synced_at = Column(DateTime(timezone=True), nullable=True)

    tickets = relationship("Ticket", back_populates="concert")
    timetable = relationship("TimeTable", back_populates="concert", uselist=False)
    real_setlist = relationship("RealSetlist", back_populates="concert", uselist=False)
    pre_setlist = relationship("PreSetlist", back_populates="concert", uselist=False)
    venue_layout = relationship("VenueLayout", back_populates="concert", uselist=False)
