from pydantic import BaseModel
from uuid import UUID
from datetime import datetime
from typing import Literal


class PriceEntry(BaseModel):
    # 좌석 등급별 가격 항목 (예: {"seat_type": "S석", "price": 150000})
    seat_type: str
    price: int


class ConcertResponse(BaseModel):
    model_config = {"from_attributes": True}

    # 공연 조회 응답
    id: UUID
    kopis_id: str | None
    name: str
    artist_name: list[str]
    venue: str | None
    start_date: datetime
    start_time: str | None
    end_date: datetime
    genre: list[str] | None
    poster_url: str | None
    description: str | None
    price: list[PriceEntry] | None
    event_type: str
    ticketing_date: datetime | None


class TicketScanExtracted(BaseModel):
    # OCR + LLM으로 추출된 티켓 정보
    title: str | None = None
    date: str | None = None           # YYYY-MM-DD
    time: str | None = None           # HH:MM
    location: str | None = None
    seat: str | None = None
    platform: str | None = None
    price: int | None = None
    shipping_date: str | None = None  # YYYY-MM-DD
    event_type: Literal["SOLO", "FESTIVAL", "UNKNOWN"] | None = None


class TicketScanResponse(BaseModel):
    # 티켓 스캔 응답 (OCR 추출 결과 + KOPIS 후보 목록)
    extracted: TicketScanExtracted
    candidates: list[ConcertResponse]
