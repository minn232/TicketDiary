from pydantic import BaseModel
from uuid import UUID


class ArtistEntry(BaseModel):
    # 팔로우 아티스트 단일 항목
    artist_name: str
    kopis_artist_id: str | None = None


class ArtistFollowUpdate(BaseModel):
    # 아티스트 팔로우 목록 수정 요청
    artists: list[ArtistEntry]


class ArtistFollowResponse(BaseModel):
    model_config = {"from_attributes": True}

    # 아티스트 팔로우 목록 조회 응답
    id: UUID
    user_id: UUID
    artists: list[ArtistEntry]


class ConcertEntry(BaseModel):
    # 팔로우 공연 단일 항목
    concert_id: UUID
    kopis_concert_id: str | None = None


class ConcertFollowUpdate(BaseModel):
    # 공연 팔로우 목록 수정 요청
    concerts: list[ConcertEntry]


class ConcertFollowResponse(BaseModel):
    model_config = {"from_attributes": True}

    # 공연 팔로우 목록 조회 응답
    id: UUID
    user_id: UUID
    concerts: list[ConcertEntry]


class NewsFeedResponse(BaseModel):
    model_config = {"from_attributes": True}

    # 뉴스피드 항목 조회 응답
    id: UUID
    user_id: UUID
    concert_id: UUID
    artist_name: str
    is_read: bool
