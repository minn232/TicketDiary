from pydantic import BaseModel, Field, field_validator, model_validator
from uuid import UUID
from datetime import datetime, timezone
from app.models.ticket import TicketStatus
from app.schemas.concert import ConcertResponse, ConcertSummary


# 클라이언트가 "2030-06-02"처럼 시간대 정보 없는 날짜 문자열을 보내면 naive datetime으로 남는데,
# DB 세션 타임존(Asia/Seoul)이 이를 KST 자정으로 해석해 UTC로 저장하면서 하루가 밀리는 버그가
# 있었음(예: "2030-06-02" -> 저장값 "2030-06-01T15:00:00Z"). naive면 UTC로 명시해서 방지
def _ensure_utc(value: datetime | None) -> datetime | None:
    if value is not None and value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value


class TicketCreate(BaseModel):
    # 티켓 생성 요청 (concert_id, kopis_id 중 하나 필수)
    concert_id: UUID | None = None
    kopis_id: str | None = None
    delivery_date: datetime | None = None
    start_time: str | None = None  # OCR로 추출한 티켓 실제 시작시간 ("HH:MM")
    ticketing_site: str | None = None
    price: int | None = None
    seat_type: str | None = None
    # OCR로 추출한 실제 관람 날짜. 있으면 등록 시점에 is_first_day/is_last_day를 자동 판정하는 데 쓰임
    attended_date: datetime | None = None

    _normalize_dates = field_validator("delivery_date", "attended_date", mode="after")(_ensure_utc)

    @model_validator(mode="after")
    def check_concert_provided(self) -> "TicketCreate":
        if self.concert_id is None and self.kopis_id is None:
            raise ValueError("concert_id 또는 kopis_id 중 하나는 필수입니다.")
        return self


class TicketUpdate(BaseModel):
    # 티켓 부분 수정 요청
    delivery_date: datetime | None = None
    start_time: str | None = None
    ticketing_site: str | None = None
    price: int | None = None
    seat_type: str | None = None
    ticket_image_url: str | None = None
    # 일기 생성 LLM 프롬프트에 그대로 들어가므로 과도한 길이로 토큰 비용이 늘지 않도록 제한
    review: str | None = Field(default=None, max_length=2000)
    concert_photo_urls: list[str] | None = None
    # 이 필드를 같이 보내면 자동 판정 대신 이 값을 그대로 씀(수동 override).
    # attended_date만 보내고 이 필드들은 안 보내면 서버가 새 attended_date 기준으로 재판정함
    attended_date: datetime | None = None
    is_first_day: bool | None = None
    is_last_day: bool | None = None
    # 공연 후 "티켓 뜯기" 연출 실행 시각. 백엔드는 값 저장만 담당, null로 되돌리는 것도 허용
    # (한 번 뜯으면 다시 뜯을 방법을 없애는 건 프론트 UI가 알아서 막음)
    torn_at: datetime | None = None

    _normalize_dates = field_validator("delivery_date", "attended_date", "torn_at", mode="after")(_ensure_utc)


class TicketResponse(BaseModel):
    model_config = {"from_attributes": True}

    id: UUID
    concert_id: UUID | None
    status: TicketStatus
    delivery_date: datetime | None
    start_time: str | None
    ticketing_site: str | None
    price: int | None
    seat_type: str | None
    ticket_image_url: str | None
    review: str | None
    diary: str | None
    # diary가 null인데 이 값이 있으면 "생성 중"(백그라운드 처리 중), 둘 다 null이면 "미요청"
    diary_requested_at: datetime | None
    concert_photo_urls: list[str] | None
    attended_date: datetime | None
    is_first_day: bool | None
    is_last_day: bool | None
    torn_at: datetime | None


class TicketWithConcert(TicketResponse):
    # 공연 정보 포함 티켓 응답 (상세 조회용 - 전체 공연 정보 포함)
    concert: ConcertResponse | None


class TicketListItem(TicketResponse):
    # 목록 조회용 - description/가격표처럼 상세 화면 전용 필드는 뺀 요약 공연 정보만 포함
    concert: ConcertSummary | None
