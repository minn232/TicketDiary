from pydantic import BaseModel
from uuid import UUID
from datetime import date


class SongEntry(BaseModel):
    # 셋리스트 곡 하나
    name: str
    encore: bool = False
    # 페스티벌처럼 아티스트가 여럿인 공연에서, 이 곡이 누구 예상/실제 셋리스트
    # 소속인지 표시. 단독 공연이면 그냥 None(불필요).
    artist: str | None = None


class SetlistEditRequest(BaseModel):
    # 실제 셋리스트 유저 수정 요청
    songs: list[SongEntry]


class FetchSetlistRequest(BaseModel):
    # Setlist.fm ID로 셋리스트 가져와 저장 요청
    setlistfm_id: str


class RealSetlistResponse(BaseModel):
    model_config = {"from_attributes": True}

    # 실제 셋리스트 조회 응답. 아직 DB에 row가 없어도(Setlist.fm에서 못 찾은 경우 포함)
    # id=None에 songs=[]인 채로 200을 내려줄 수 있음 - artist_names(콘서트에 등록된
    # 아티스트 전원)는 그 경우에도 채워져서, 프론트가 "아티스트는 있는데 아직 못
    # 찾음"을 구분해 안내 문구를 보여줄 수 있음.
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
