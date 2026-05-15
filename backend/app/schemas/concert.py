from pydantic import BaseModel
from uuid import UUID
from datetime import datetime


class PriceEntry(BaseModel):
    # 좌석 등급별 가격 항목 (예: {"seat_type": "S석", "price": 150000})
    seat_type: str
    price: int


class ConcertCreate(BaseModel):
    # 공연 생성 요청
    kopis_id: str | None = None
    name: str
    artist_name: list[str]
    venue: str | None = None
    start_date: datetime
    end_date: datetime
    genre: list[str] | None = None
    poster_url: str | None = None
    description: str | None = None
    price: list[PriceEntry] | None = None


class ConcertUpdate(BaseModel):
    # 공연 부분 수정 요청
    name: str | None = None
    artist_name: list[str] | None = None
    venue: str | None = None
    start_date: datetime | None = None
    end_date: datetime | None = None
    genre: list[str] | None = None
    poster_url: str | None = None
    description: str | None = None
    price: list[PriceEntry] | None = None


class ConcertResponse(BaseModel):
    model_config = {"from_attributes": True}

    # 공연 조회 응답
    id: UUID
    kopis_id: str | None
    name: str
    artist_name: list[str]
    venue: str | None
    start_date: datetime
    end_date: datetime
    genre: list[str] | None
    poster_url: str | None
    description: str | None
    price: list[PriceEntry] | None


class TicketScanExtracted(BaseModel):
    # OCR로 추출된 티켓 정보
    artist_name: str | None = None
    venue: str | None = None
    event_date: str | None = None  # YYYY-MM-DD


class TicketScanResponse(BaseModel):
    # 티켓 스캔 응답 (OCR 추출 결과 + KOPIS 후보 목록)
    extracted: TicketScanExtracted
    candidates: list[ConcertResponse]
