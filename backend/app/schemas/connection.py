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
    # 두 폰이 같은 순간에 상대 카드를 펼치는 서버 시각 - 앱이 server_time으로 시계 차이를 재서 맞춤
    reveal_at: datetime | None = None
    server_time: datetime


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
    # connected일 때 두 폰이 같은 순간에 연결 완료 애니메이션을 시작하는 서버 시각
    finish_at: datetime | None = None
    server_time: datetime


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


class Taste(BaseModel):
    # 한 사람의 취향 요약 (예: "영미권 록/밴드") - 문장은 앱에서 조합
    # origins: 아티스트 국적 큰 줄기 1~2개(많은 순), origin_mixed면 세 줄기 이상 고르게 섞임("여러 나라")
    # 둘 다 비어 있으면 국적 정보 부족. genres: 대표 장르 0~2개(결산과 같은 장르 라벨)
    origins: list[Literal["domestic", "japan", "anglo", "other"]]
    origin_mixed: bool
    genres: list[str]


class CardUs(BaseModel):
    # "우리 사이" - 같이 간 공연·취향·궁합·공통 아티스트
    together_count: int
    latest_together_poster_url: str | None
    compatibility: Compatibility | None
    common_artists: list[str]
    # 각자 취향 요약 - 판단할 데이터가 부족하면 None
    my_taste: Taste | None = None
    peer_taste: Taste | None = None


class SharedSong(BaseModel):
    # 둘 다 라이브로 들은 곡 - times는 둘 중 누구든 들은 공연(회차) 수 (같이 본 공연은 1번)
    name: str
    artist: str | None
    times: int


class SameConcertOtherDay(BaseModel):
    # 같은 공연을 서로 다른 날 본 경우
    concert: CardConcert
    my_date: date
    peer_date: date


class CardHistory(BaseModel):
    # "함께한 기록" - 앱은 "우리 사이"와 같은 장에 보여줌
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
    # "다음에 같이" - 각자 다음 공연이 같으면 together_next 하나로 합침
    # 상대가 공개를 끄면 peer_next는 비고 peer_next_hidden=True (둘 다 예매한 공연은 그래도 보임)
    my_next: CardConcert | None
    peer_next: CardConcert | None
    together_next: CardConcert | None
    peer_next_hidden: bool
    both_interested: list[InterestedConcert]
    # 같이 가볼 만한 다가오는 공연 - 공통 아티스트 공연 먼저, 남는 자리는 둘 다 좋아하는 장르 공연.
    # 근거: 전부 아티스트 "artist" / 전부 장르 "genre" / 섞임 "mixed"
    suggestions: list[CardConcert]
    suggestion_basis: Literal["artist", "genre", "mixed"] | None = None


class ConnectionCardResponse(BaseModel):
    # 연결 카드 (우리 사이 / 함께한 기록 / 다음에 같이)
    peer: ConnectionPeer
    connected_at: datetime
    last_met_at: datetime | None
    us: CardUs
    history: CardHistory
    next: CardNext
