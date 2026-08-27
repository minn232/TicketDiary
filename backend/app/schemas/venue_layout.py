from uuid import UUID

from pydantic import BaseModel

from app.schemas.concert import TicketingPhaseEntry
from app.schemas.lineup import LineupEntry
from app.schemas.timetable import TimeTableEntry


class VenueLayoutInput(BaseModel):
    # 좌석 배치도 입력 (크롤링 결과 웹훅 전용)
    image_url: str | None = None
    layout_data: dict | None = None


class VenueLayoutResponse(BaseModel):
    # 좌석 배치도 조회 응답
    model_config = {"from_attributes": True}

    id: UUID
    concert_id: UUID
    image_url: str | None
    layout_data: dict | None


class CrawlResultRequest(BaseModel):
    # 크롤링 결과 웹훅 요청 - 필드는 있는 것만 갱신, 안 보낸 필드는 기존값 유지
    timetable: list[TimeTableEntry] | None = None
    prices: list[dict] | None = None
    venue_layout: VenueLayoutInput | None = None
    ticketing_date: str | None = None  # YYYY-MM-DD
    # 선예매/1차/2차 등 예매 단계별 전체 내역 (llm_server/normalize.py가 ticketing_date와
    # 함께 원본 배열 그대로 실어보냄 - ticketing_date는 이 중 가장 이른 날짜만 담은 것)
    ticketing_phases: list[TicketingPhaseEntry] | None = None
    delivery_date: str | None = None  # YYYY-MM-DD, 예매 사이트에 공지된 배송 예정일
    # 예매 사이트 라인업 텍스트에서 추출한 아티스트명. 포스터 기반 추출(artist-result 웹훅)이
    # 페스티벌처럼 출연진이 많은 공연에서 실패하기 쉬운 걸 보완하는 대체 경로
    artist_name: list[str] | None = None
    # 아티스트별 실제 출연일(날짜를 아는 항목만 옴) - concert_lineups에 upsert되어 날짜별
    # 셋리스트 필터링(app/services/setlist.py, pre_setlist.py)에 쓰임
    lineup: list[LineupEntry] | None = None
    # 음식물 반입 가능 여부 ("가능"/"불가능"/"일부허용"), 언급이 없으면 생략
    food_allowed: str | None = None


class CrawlResultResponse(BaseModel):
    # 크롤링 결과 웹훅 응답 - 실제로 갱신된 필드명 목록
    updated: list[str]
