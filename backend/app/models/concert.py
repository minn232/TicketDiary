import uuid
import enum

from sqlalchemy import Column, String, DateTime, Text, Integer, text
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
    # 가장 최근 크롤링 시도 시각(성공/실패 무관). ticketing_date를 아직 못 얻었으면 크롤링을
    # "완료"로 보지 않고 재시도하되, 너무 자주 재시도하지 않도록 쿨다운 판단에 씀
    crawl_attempted_at = Column(DateTime(timezone=True), nullable=True)
    # 크롤링 시도 누적 횟수. 영영 ticketing_date를 못 얻는 공연(검색 실패 등)에 매일 무한정
    # 재시도하지 않도록 _MAX_CRAWL_ATTEMPTS(crawler.py)와 비교해 포기 시점을 판단하는 데 씀
    crawl_attempt_count = Column(Integer, nullable=False, default=0, server_default=text("0"))
    ticketing_date = Column(DateTime(timezone=True), nullable=True)
    # 예매 사이트 크롤링 결과로 채워지는 배송 예정일 공지 (사이트 공통 공지라 티켓별이 아닌 공연 단위)
    delivery_date = Column(DateTime(timezone=True), nullable=True)
    ticketing_links = Column(JSONB, nullable=True)
    # 음식물 반입 가능 여부 크롤링 결과 ("가능"/"불가능"/"일부허용"), 언급 없으면 None
    food_allowed = Column(String, nullable=True)
    # KOPIS 상세 API(/pblprfr/{id})로 아티스트/가격 등을 채운 시점. 검색(목록 API) 경유로만
    # 생성된 공연은 이 값이 None이라 artist_name이 비어 있어도 "진짜 출연진 없음"과 구분 못하므로,
    # 상세 조회 시 이 값 유무로 재조회 필요 여부를 판단함 (None이면 아직 상세 미조회)
    kopis_detail_synced_at = Column(DateTime(timezone=True), nullable=True)
    # 포스터를 VLM팀에 아티스트 추출 요청으로 보낸 시점(성공/실패 무관). 포스터 내용은 시간이 지나도
    # 안 바뀌므로 크롤링과 달리 재시도 개념 없이 한 번만 보내고 다시 보내지 않기 위한 플래그
    artist_extraction_attempted_at = Column(DateTime(timezone=True), nullable=True)
    # 페스티벌 라인업 변경 감지용 직전 스냅샷(조회수/광고 등 노이즈 제거된 본문 해시 + 이미지 경로 목록).
    # crawl_attempted_at/ticketing_date와는 목적이 달라 별도 필드로 분리 - 저건 "티켓팅일 확보" 완료
    # 판단용, 이건 "라인업이 직전과 달라졌는가" 비교용
    lineup_snapshot_hash = Column(String, nullable=True)
    lineup_snapshot_img_srcs = Column(ARRAY(String), nullable=True)
    # 라인업 재크롤링 마지막 시도 시각 (재시도 쿨다운 판단용, crawl_attempted_at과 별개 시계)
    lineup_check_attempted_at = Column(DateTime(timezone=True), nullable=True)

    tickets = relationship("Ticket", back_populates="concert")
    timetable = relationship("TimeTable", back_populates="concert", uselist=False)
    # 한 공연(concert_id)이 여러 날짜에 걸치면 실제 셋리스트도 날짜별로 다를 수 있어서
    # (RealSetlist.performance_date), 더 이상 1:1이 아님
    real_setlists = relationship("RealSetlist", back_populates="concert")
    pre_setlist = relationship("PreSetlist", back_populates="concert", uselist=False)
    venue_layout = relationship("VenueLayout", back_populates="concert", uselist=False)
