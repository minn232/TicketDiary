from pydantic import BaseModel
from uuid import UUID
from datetime import datetime
from app.models.ticket import TicketStatus


class TicketCreate(BaseModel):
    # 티켓 생성 요청
    concert_id: UUID
    delivery_date: datetime | None = None
    ticketing_site: str | None = None
    price: int | None = None
    seat_type: str | None = None


class TicketUpdate(BaseModel):
    # 티켓 부분 수정 요청
    status: TicketStatus | None = None
    delivery_date: datetime | None = None
    ticketing_site: str | None = None
    price: int | None = None
    seat_type: str | None = None
    ticket_image_url: str | None = None
    review: str | None = None
    concert_photo_urls: str | None = None
    is_first_day: bool | None = None
    is_last_day: bool | None = None


class TicketResponse(BaseModel):
    model_config = {"from_attributes": True}

    # 티켓 조회 응답
    id: UUID
    concert_id: UUID | None
    status: TicketStatus
    delivery_date: datetime | None
    ticketing_site: str | None
    price: int | None
    seat_type: str | None
    ticket_image_url: str | None
    review: str | None
    concert_photo_urls: str | None
    is_first_day: bool | None
    is_last_day: bool | None
