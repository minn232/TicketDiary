from pydantic import BaseModel
from uuid import UUID
from datetime import datetime


class ArtistEntry(BaseModel):
    # 팔로우 아티스트 단일 항목
    artist_name: str
    kopis_artist_id: str | None = None


class ArtistFollowUpdate(BaseModel):
    # 선호 아티스트 수정 요청 (전체 교체)
    artists: list[ArtistEntry]


class ArtistFollowResponse(BaseModel):
    model_config = {"from_attributes": True}

    # 선호 아티스트 조회 응답
    id: UUID
    user_id: UUID
    artists: list[ArtistEntry]


class ConcertEntry(BaseModel):
    # 찜 공연 단일 항목
    concert_id: UUID
    kopis_concert_id: str | None = None


class ConcertFollowUpdate(BaseModel):
    # 찜 공연 수정 요청 (전체 교체)
    concerts: list[ConcertEntry]


class ConcertFollowResponse(BaseModel):
    model_config = {"from_attributes": True}

    # 찜 공연 조회 응답
    id: UUID
    user_id: UUID
    concerts: list[ConcertEntry]


class NewsFeedConcert(BaseModel):
    # 뉴스 피드 공연 정보
    id: UUID
    name: str
    poster_url: str | None
    start_date: datetime
    end_date: datetime
    venue: str | None


class NewsFeedResponse(BaseModel):
    model_config = {"from_attributes": True}

    # 뉴스 피드 항목 조회 응답
    id: UUID
    user_id: UUID
    concert_id: UUID
    artist_name: str
    is_read: bool
    concert: NewsFeedConcert | None = None
