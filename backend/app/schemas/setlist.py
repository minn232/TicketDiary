from pydantic import BaseModel
from uuid import UUID
from datetime import date


class SongEntry(BaseModel):
    name: str
    encore: bool = False
    # 페스티벌처럼 아티스트가 여럿인 공연에서, 이 곡이 누구 예상/실제 셋리스트
    # 소속인지 표시. 단독 공연이면 그냥 None(불필요).
    artist: str | None = None


class SetlistEditRequest(BaseModel):
    songs: list[SongEntry]


class FetchSetlistRequest(BaseModel):
    setlistfm_id: str


class RealSetlistResponse(BaseModel):
    model_config = {"from_attributes": True}

    # 실제 셋리스트 조회 응답. row가 없어도(Setlist.fm 매칭 실패 등) id=None/songs=[]로
    # 200을 반환할 수 있음 - artist_names는 그 경우에도 채워져서 프론트가 아티스트별
    # 안내 문구를 보여줄 수 있음.
    id: UUID | None = None
    concert_id: UUID
    performance_date: date
    setlistfm_id: str | None
    songs: list[SongEntry]
    is_user_edited: bool
    edited_user_nickname: str | None
    artist_names: list[str] = []


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
