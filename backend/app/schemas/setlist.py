import json
from pydantic import BaseModel, field_validator
from uuid import UUID


class SongEntry(BaseModel):
    name: str
    encore: bool = False


class SetlistEditRequest(BaseModel):
    songs: list[SongEntry]


class FetchSetlistRequest(BaseModel):
    setlistfm_id: str


class RealSetlistResponse(BaseModel):
    model_config = {"from_attributes": True}

    # 실제 셋리스트 조회 응답
    id: UUID
    concert_id: UUID
    setlistfm_id: str | None
    songs: list[SongEntry]
    is_user_edited: bool
    edited_user_nickname: str | None

    # DB에 JSON 문자열로 저장된 songs를 리스트로 파싱
    @field_validator("songs", mode="before")
    @classmethod
    def parse_songs(cls, v) -> list:
        if isinstance(v, str):
            return json.loads(v)
        return v


class SetlistFmCandidate(BaseModel):
    # Setlist.fm 검색 결과 후보 항목
    setlistfm_id: str
    event_date: str
    artist_name: str
    venue_name: str
    city_name: str
    song_count: int
    songs: list[SongEntry]
    url: str


class PreSetlistResponse(BaseModel):
    model_config = {"from_attributes": True}

    # 예상 셋리스트 조회 응답
    id: UUID
    concert_id: UUID
    setlistfm_id: str | None
    songs: list[SongEntry]
    is_user_edited: bool
    edited_user_nickname: str | None

    @field_validator("songs", mode="before")
    @classmethod
    def parse_songs(cls, v) -> list:
        if isinstance(v, str):
            return json.loads(v)
        return v
