from uuid import UUID

from pydantic import BaseModel

from app.schemas.timetable import TimeTableEntry


class VenueLayoutInput(BaseModel):
    image_url: str | None = None
    layout_data: dict | None = None


class VenueLayoutResponse(BaseModel):
    model_config = {"from_attributes": True}

    id: UUID
    concert_id: UUID
    image_url: str | None
    layout_data: dict | None


class CrawlResultRequest(BaseModel):
    timetable: list[TimeTableEntry] | None = None
    prices: list[dict] | None = None
    venue_layout: VenueLayoutInput | None = None
    ticketing_date: str | None = None  # YYYY-MM-DD
    delivery_date: str | None = None  # YYYY-MM-DD, 예매 사이트에 공지된 배송 예정일


class CrawlResultResponse(BaseModel):
    updated: list[str]
