from pydantic import BaseModel
from uuid import UUID
from datetime import datetime
from typing import Literal


class PriceEntry(BaseModel):
    # 좌석 등급별 가격 항목 (예: {"seat_type": "S석", "price": 150000})
    seat_type: str
    price: int


class TicketingPhaseEntry(BaseModel):
    # 예매 단계 1건 (예: {"phase": "선예매", "date": "2026-08-25"}). LLM팀 크롤링 추출 결과
    # 원본 포맷 그대로 사용 - date는 해당 단계의 날짜를 아직 특정할 수 없으면 null
    phase: str
    date: str | None = None  # YYYY-MM-DD


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
    # 선예매/1차/2차 등 예매 단계별 전체 내역 (ticketing_date는 이 중 가장 이른 날짜만 담음)
    ticketing_phases: list[TicketingPhaseEntry] | None
    delivery_date: datetime | None
    food_allowed: str | None
    # 예매처 바로가기 버튼용. KOPIS relates에서 파싱한 사이트별 URL
    # (키: YES24/INTERPARK/TICKETLINK/MELON, site_aliases.py 참고).
    ticketing_links: dict[str, str] | None


class ConcertSummary(BaseModel):
    model_config = {"from_attributes": True}

    # 티켓 목록처럼 여러 건을 한 번에 내려주는 화면용 - 상세 화면에서만 쓰는
    # description/price(가격표)는 빼서 응답 크기를 줄임
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
    event_type: str
    ticketing_date: datetime | None
    delivery_date: datetime | None


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


class ArtistNameConfirmRequest(BaseModel):
    # 미확정 아티스트 표기를 유저가 직접 확정(G안) - original_name은 지금 concert.artist_name에
    # 실제로 들어있는 표기여야 함
    original_name: str
    confirmed_name: str


class ArtistNameConfirmResponse(BaseModel):
    # 치환 후 concert.artist_name 전체 배열
    artist_name: list[str]
