import json
from pydantic import BaseModel, model_validator, field_validator
from uuid import UUID
from datetime import datetime
from app.models.ticket import TicketStatus
from app.schemas.concert import ConcertResponse


class TicketCreate(BaseModel):
    # 티켓 생성 요청
    concert_id: UUID | None = None
    kopis_id: str | None = None
    concert_name: str | None = None
    concert_date: datetime | None = None
    artist_name: list[str] | None = None
    delivery_date: datetime | None = None
    ticketing_site: str | None = None
    price: int | None = None
    seat_type: str | None = None

    # concert_name으로 등록시 concert_date 필수
    # concert_id, kopis_id, concert_name 중 하나 필수
    @model_validator(mode="after")
    def check_concert_provided(self) -> "TicketCreate":
        if not any([self.concert_id, self.kopis_id, self.concert_name]):
            raise ValueError("concert_id, kopis_id, concert_name 중 하나는 필수입니다.")
        if self.concert_name and not self.concert_date:
            raise ValueError("concert_name으로 등록할 때는 concert_date가 필요합니다.")
        return self


class TicketUpdate(BaseModel):
    # 티켓 부분 수정 요청
    status: TicketStatus | None = None
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
    concert_photo_urls: list[str] | None
    is_first_day: bool | None
    is_last_day: bool | None

    # concert_photo_urls에서 JSON 문자열 -> 리스트
    @field_validator("concert_photo_urls", mode="before")
    @classmethod
    def parse_concert_photo_urls(cls, v: str | list | None) -> list[str] | None:
        if isinstance(v, str):
            return json.loads(v)
        return v


class TicketWithConcert(TicketResponse):
    # 공연 정보 포함 티켓 응답
    concert: ConcertResponse | None
