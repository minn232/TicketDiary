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
    # 예매 사이트 라인업 텍스트에서 추출한 아티스트명. 포스터 기반 추출(artist-result 웹훅)이
    # 페스티벌처럼 출연진이 많은 공연에서 실패하기 쉬운 걸 보완하는 대체 경로
    artist_name: list[str] | None = None
    # 음식물 반입 가능 여부 ("가능"/"불가능"/"일부허용"), 언급이 없으면 생략
    food_allowed: str | None = None


class CrawlResultResponse(BaseModel):
    updated: list[str]
