from datetime import date, datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field


class NearbyCodeResponse(BaseModel):
    # 내 BLE 광고 코드 - 앱은 만료 1시간 전부터 새로 받아 둠(오프라인에서도 쓸 수 있게)
    code: str
    valid_until: datetime


class NearbySightingCreate(BaseModel):
    # 폰이 "이 코드를 맞댐 수준으로 봤다"고 올리는 판정 - 오프라인이면 저장했다가 나중에 올림
    code: str = Field(pattern=r"^[0-9a-f]{8}$")
    rssi: int | None = None
    seen_at: datetime


class ConnectionPeer(BaseModel):
    # 연결 상대 프로필 ("OO님 맞나요?" 확인 화면·연결 목록용)
    user_id: UUID
    nickname: str | None
    profile_image_url: str | None


class NearbySightingResponse(BaseModel):
    # waiting=상대 판정 아직 없음 / pending=양쪽 판정 모임, 확인 필요 / connected=이미 연결된 사이
    status: Literal["waiting", "pending", "connected"]
    connection_id: UUID | None = None
    peer: ConnectionPeer | None = None
    # pending일 때 내가 이미 확인했는지 (상대 확인만 기다리는 중인지)
    confirmed_by_me: bool = False


class ConnectionRequestResponse(BaseModel):
    # 확인 대기 중인 연결 요청
    connection_id: UUID
    peer: ConnectionPeer
    requested_at: datetime
    confirmed_by_me: bool


class ConnectionResponse(BaseModel):
    # 연결된 상대
    connection_id: UUID
    peer: ConnectionPeer
    connected_at: datetime
    last_met_at: datetime | None


class ConnectionConfirmResponse(BaseModel):
    # 확인 결과 - 상대도 확인했으면 connected
    status: Literal["pending", "connected"]
    connection_id: UUID


class CardConcert(BaseModel):
    # 카드에 보여줄 공연 요약 - attended_date는 관람(예정)일을 알 때만
    id: UUID
    name: str
    poster_url: str | None
    venue: str | None
    start_date: datetime
    end_date: datetime
    attended_date: date | None = None
    ticketing_date: datetime | None = None


class Compatibility(BaseModel):
    # 취향 궁합 - 장르 분포·겹치는 아티스트·국내/내한 비율로 계산한 0~100 점수
    score: int
    top_shared_genre: str | None
    shared_artist_count: int


class CardUs(BaseModel):
    # 1장 "우리 사이" - 같이 간 공연이 없으면 앱은 공통 아티스트로 대체
    together_count: int
    latest_together_poster_url: str | None
    compatibility: Compatibility | None
    common_artists: list[str]


class SharedSong(BaseModel):
    # 둘 다 라이브로 들은 곡 - times는 두 사람이 들은 횟수 합
    name: str
    artist: str | None
    times: int


class SameConcertOtherDay(BaseModel):
    # 같은 공연을 서로 다른 날 본 경우
    concert: CardConcert
    my_date: date
    peer_date: date


class CardHistory(BaseModel):
    # 2장 "함께한 기록"
    together_concerts: list[CardConcert]
    shared_song_count: int
    shared_songs: list[SharedSong]
    same_concert_other_days: list[SameConcertOtherDay]


class InterestedConcert(BaseModel):
    # 둘 다 관심 있는 다가오는 공연 - 각자 예매(ticket)했는지 찜(follow)만 했는지
    concert: CardConcert
    my_status: Literal["ticket", "follow"]
    peer_status: Literal["ticket", "follow"]


class CardNext(BaseModel):
    # 3장 "다음에 같이" - 각자 다음 공연이 같으면 together_next 하나로 합침.
    # 상대가 공개를 끄면 peer_next는 비고 peer_next_hidden=True (둘 다 예매한 공연은 그래도 보임)
    my_next: CardConcert | None
    peer_next: CardConcert | None
    together_next: CardConcert | None
    peer_next_hidden: bool
    both_interested: list[InterestedConcert]
    # 둘 다 관심 공연이 없을 때 대신 보여줄, 공통 아티스트의 다가오는 공연
    suggestions: list[CardConcert]


class ConnectionCardResponse(BaseModel):
    # 연결 카드 3장
    peer: ConnectionPeer
    connected_at: datetime
    last_met_at: datetime | None
    us: CardUs
    history: CardHistory
    next: CardNext
