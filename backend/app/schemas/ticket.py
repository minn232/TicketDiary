from pydantic import BaseModel, model_validator
from uuid import UUID
from datetime import datetime
from app.models.ticket import TicketStatus
from app.schemas.concert import ConcertResponse


class TicketCreate(BaseModel):
    # 티켓 생성 요청 (concert_id, kopis_id 중 하나 필수)
    concert_id: UUID | None = None
    kopis_id: str | None = None
    delivery_date: datetime | None = None
    ticketing_site: str | None = None
    price: int | None = None
    seat_type: str | None = None

    @model_validator(mode="after")
    def check_concert_provided(self) -> "TicketCreate":
        if self.concert_id is None and self.kopis_id is None:
            raise ValueError("concert_id 또는 kopis_id 중 하나는 필수입니다.")
        return self


class TicketUpdate(BaseModel):
    # 티켓 부분 수정 요청
    delivery_date: datetime | None = None
    ticketing_site: str | None = None
    price: int | None = None
    seat_type: str | None = None
    ticket_image_url: str | None = None
    review: str | None = None
    concert_photo_urls: list[str] | None = None
    is_first_day: bool | None = None
    is_last_day: bool | None = None


class TicketResponse(BaseModel):
    model_config = {"from_attributes": True}

    id: UUID
    concert_id: UUID | None
    status: TicketStatus
    delivery_date: datetime | None
    ticketing_site: str | None
    price: int | None
    seat_type: str | None
    ticket_image_url: str | None
    review: str | None
    concert_photo_urls: list[str] | None
    is_first_day: bool | None
    is_last_day: bool | None


class TicketWithConcert(TicketResponse):
    # 공연 정보 포함 티켓 응답
    concert: ConcertResponse | None
