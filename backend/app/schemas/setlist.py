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
    # 곡 출처 - "representative"면 과거 셋리가 없어 대신 채운 대표곡(화면에서 예상 셋리와
    # 구분 표시), None이면 Setlist.fm 셋리 기반
    source: str | None = None


class SetlistEditRequest(BaseModel):
    # 실제 셋리스트 유저 수정 요청
    songs: list[SongEntry]


class FetchSetlistRequest(BaseModel):
    # Setlist.fm ID로 셋리스트 가져와 저장 요청
    setlistfm_id: str


class ArtistSetlistStatus(BaseModel):
    # 실제 셋리가 빈 아티스트의 상태(앱 빈 화면 문구용) - searching(아직 안 찾아봄)/searched(찾았지만
    # 없음)/unresolved(mbid 없어 누구인지 확정 못함)/not_artist("아티스트가 아니에요"로 설정됨)
    artist: str
    state: str
    name: str | None = None
    # 누구로 찾았는지 알아보게 붙이는 대표곡 1곡(searching/searched만)
    top_song: str | None = None


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
    artist_statuses: list[ArtistSetlistStatus] = []


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

    # 예상 셋리스트 조회 응답 - id가 None이면 아직 row가 없음(빈 songs + artist_names만)
    id: UUID | None = None
    concert_id: UUID
    setlistfm_id: str | None
    songs: list[SongEntry]
    is_user_edited: bool
    edited_user_nickname: str | None
    # RealSetlistResponse와 동일 패턴 - 프론트가 단독 공연에서 song.artist가
    # 비어있는 곡을 음악앱 검색으로 연결할 때 폴백 아티스트로 씀.
    artist_names: list[str] = []


class ArtistCandidate(BaseModel):
    # 앵커 후보(공연 아티스트 이름으로 찾은 iTunes 아티스트) - 동명이인은 장르/대표곡으로 구분
    itunes_artist_id: str
    artist_name: str
    genre: str | None = None
    top_songs: list[str] = []
    artwork_url: str | None = None
    # 공연 아티스트 이름과 정확히 같은지(아니면 협업/편집 앨범 등 비슷한 이름)
    exact_match: bool = False


class ArtistAnchorCandidate(BaseModel):
    # 앵커 후보(iTunes 곡 검색 결과) - 유저가 고르면 이 곡의 아티스트로 확정
    itunes_artist_id: str
    artist_name: str
    track_name: str
    album_name: str | None = None
    artwork_url: str | None = None


class ArtistAnchorRequest(BaseModel):
    # 공연의 어느 아티스트(concert.artist_name 중 하나)를 어느 iTunes 아티스트로 확정할지
    artist: str
    itunes_artist_id: str
