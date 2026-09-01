from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


class AdminConcertListItem(BaseModel):
    model_config = {"from_attributes": True}

    # 관리자 목록 한 줄 - flagged_count는 unconfirmed/ambiguous 상태인 아티스트 수(0이면 정상)
    id: UUID
    kopis_id: str | None
    name: str
    artist_name: list[str]
    poster_url: str | None
    start_date: datetime
    flagged_count: int


class AdminConcertListResponse(BaseModel):
    # 페이지네이션 포함 목록 응답
    items: list[AdminConcertListItem]
    total: int
    page: int
    page_size: int


class AdminArtistStatus(BaseModel):
    # 아티스트 표기 하나의 정규화 상태 (concert 상세 화면에서 뱃지로 보여주기 위함)
    artist_text: str
    status: str
    attempt_count: int


class AdminConcertDetail(BaseModel):
    model_config = {"from_attributes": True}

    # 상세 화면 - 포스터 원본과 대조하며 검수/수정하기 위한 필드 구성
    id: UUID
    kopis_id: str | None
    name: str
    artist_name: list[str]
    poster_url: str | None
    venue: str | None
    start_date: datetime
    ticketing_links: dict[str, str] | None
    statuses: list[AdminArtistStatus]


class AdminArtistRenameRequest(BaseModel):
    # confirm_artist_name_change에 그대로 넘기는 페이로드(G안과 동일 로직)
    original_name: str
    confirmed_name: str
