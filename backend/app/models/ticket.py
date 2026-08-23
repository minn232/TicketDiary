import uuid
import enum

from sqlalchemy import Column, String, DateTime, ForeignKey, Enum as SAEnum, Text, Integer, Boolean, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID, JSONB
from sqlalchemy.orm import relationship

from app.core.database import Base


# 티켓 상태 (배송 전 / 공연 전 / 공연 후)
class TicketStatus(str, enum.Enum):
    BEFORE_DELIVERY = "before_delivery"
    BEFORE_CONCERT = "before_concert"
    AFTER_CONCERT = "after_concert"


# concert_photo_urls JSON 형식: ["https://example.com/photo1.jpg", "https://example.com/photo2.jpg"]
class Ticket(Base):
    __tablename__ = "tickets"

    __table_args__ = (UniqueConstraint("user_id", "concert_id"),)

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=False, index=True)
    concert_id = Column(UUID(as_uuid=True), ForeignKey("concerts.id"), nullable=True, index=True)
    status = Column(SAEnum(TicketStatus, values_callable=lambda x: [e.value for e in x]), default=TicketStatus.BEFORE_DELIVERY)
    delivery_date = Column(DateTime(timezone=True), nullable=True)
    # True면 delivery_date가 concert.delivery_date(크롤링)에서 그대로 복사된 값이라 크롤링이
    # 정정되면 같이 갱신해도 됨. False/None이면 유저 입력 또는 OCR로 직접 채운 값이라 자동 갱신 금지
    delivery_date_synced = Column(Boolean, nullable=True)
    # 티켓 등록 시 OCR로 추출한 실제 회차 시작시간 ("HH:MM"), 없으면 concert.start_time으로 폴백
    start_time = Column(String, nullable=True)
    ticketing_site = Column(String, nullable=True)
    price = Column(Integer, nullable=True)
    seat_type = Column(String, nullable=True)
    ticket_image_url = Column(String, nullable=True)
    review = Column(Text, nullable=True)
    diary = Column(Text, nullable=True)
    # 일기 생성 요청 시각 (백그라운드로 처리되므로, 클라이언트가 diary=null이면서 이 값이
    # 있으면 "생성 중"으로, 둘 다 null이면 "아직 요청 안 함"으로 구분해서 폴링에 활용)
    diary_requested_at = Column(DateTime(timezone=True), nullable=True)
    concert_photo_urls = Column(JSONB, nullable=True)
    # 실제 관람 날짜 (OCR로 티켓에서 추출, "YYYY-MM-DD"). is_first_day/is_last_day 자동 판정에
    # 쓰임 - concert.start_date/end_date와 비교해 등록 시점에 한 번 계산해서 저장(services/ticket.py
    # 참고). OCR 없이 등록됐거나 날짜를 못 읽었으면 None이라 자동 판정도 안 됨(수동 PATCH로만 채워짐)
    attended_date = Column(DateTime(timezone=True), nullable=True)
    is_first_day = Column(Boolean, nullable=True)
    is_last_day = Column(Boolean, nullable=True)
    # 공연 후 "티켓 뜯기" 연출을 실행한 시각 (프론트 전용 애니메이션 상태 영속화용).
    # 공연전 여부/일회성 여부는 백엔드에서 강제하지 않음 - 프론트가 뜯은 뒤엔 다시 뜯을
    # 방법 자체를 UI에서 없애는 방식으로 막고 있어서 백엔드는 그냥 값 저장만 담당
    torn_at = Column(DateTime(timezone=True), nullable=True)

    concert = relationship("Concert", back_populates="tickets")
