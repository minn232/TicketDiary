from pydantic import BaseModel
from typing import Literal


class ArtistVisitCount(BaseModel):
    # 관람 아티스트 한 명 + 관람 횟수
    name: str
    count: int


class NameCount(BaseModel):
    # 이름 + 횟수 (공연장 순위 등)
    name: str
    count: int


class MaxSpend(BaseModel):
    # 가장 비싼 티켓 1장의 공연명과 가격
    concert_name: str
    price: int


class TicketingSiteShare(BaseModel):
    # 예매처 한 곳의 티켓 수와 비중
    name: str
    count: int
    percent: int  # 예매처를 아는 티켓끼리 합 100


class BusiestMonth(BaseModel):
    # 한 달 최다 관람한 달
    month: str  # "YYYY-MM"
    count: int


class MonthlyStat(BaseModel):
    # 월별 관람 수와 지출 (그래프용)
    month: str  # "YYYY-MM"
    concert_count: int
    spent: int  # 가격 없는 티켓은 0으로 침


class TopSpendArtist(BaseModel):
    # 솔로 공연 티켓 가격 합계가 가장 큰 아티스트
    name: str
    amount: int


class HeardSong(BaseModel):
    # 실제 셋리에서 여러 번 들은 곡
    name: str
    artist: str | None
    count: int


class RareSong(BaseModel):
    # 예상 셋리 확률이 가장 낮았던 곡
    name: str
    artist: str | None
    concert_name: str
    probability: float  # 예상 셋리 확률, 예상 목록에 없던 곡은 0


class SummaryResponse(BaseModel):
    # 기간별 결산 응답
    period: Literal["6m", "1y", "all"]
    concert_count: int
    song_count: int       # 실제 셋리스트 기준 합산
    # 셋리스트 없는 솔로 공연의 곡 수 어림치(러닝타임 ÷ 5분). song_count와 별개라 합칠지는 앱이 정함
    song_count_estimated: int
    # 솔로 공연 러닝타임 합계(분). 페스티벌/러닝타임 모르는 티켓 수는 runtime_missing_count
    total_runtime_minutes: int
    runtime_missing_count: int
    total_spent: int
    top_genre: str | None
    top_genres: list[str]  # 공동 1위 장르 전부(동률이면 여러 개, top_genre는 그 첫 번째)
    artists: list[ArtistVisitCount]  # 관람 횟수 내림차순(동률이면 처음 본 순서)
    standing_count: int
    seated_count: int
    first_day_count: int
    last_day_count: int
    # 합 100인 정수 퍼센트(대상 없으면 null) - 스탠딩/좌석은 seat_type이 있는 티켓끼리,
    # 첫콘/막콘은 이틀짜리 공연 티켓끼리
    standing_percent: int | None
    seated_percent: int | None
    first_day_percent: int | None
    last_day_percent: int | None
    top_venues: list[NameCount]          # 가장 많이 간 공연장 상위 3개
    weekday_counts: list[int]            # 월~일 7칸 공연 수(관람일 기준)
    max_spend: MaxSpend | None           # 가장 비싼 티켓 1장
    avg_ticket_price: int | None         # 가격 있는 티켓 평균
    ticketing_sites: list[TicketingSiteShare]  # INTERPARK/NOL 합침, 예매처 모르는 티켓 제외
    ticketing_site_unknown_count: int
    photo_count: int                     # 사진 총 장수
    diary_count: int                     # 일기 쓴 공연 수
    busiest_month: BusiestMonth | None   # 한 달 최다 관람(동률이면 최근 달)
    # 월별 관람 수/지출(오래된 달부터, 빈 달은 0). 6m/1y는 기간 시작 달부터라 7/13개월일 수 있음
    monthly_stats: list[MonthlyStat]
    top_spend_artist: TopSpendArtist | None  # 아티스트 1명인 공연 티켓 가격만 합산
    new_artist_count: int                # 선택 기간 이전 전체 기록에 없던 아티스트
    new_artists: list[str]
    origin_domestic_percent: int | None  # 국내/해외 아티스트 공연(합 100, 미분류 제외)
    origin_foreign_percent: int | None
    origin_unknown_count: int
    most_heard_song: HeardSong | None    # 실제 셋리에서 2번 이상 들은 곡 중 최다
    rarest_song: RareSong | None         # 예상 셋리 확률이 가장 낮은 곡


class RegionalVisit(BaseModel):
    latitude: float
    longitude: float
    count: int


class RegionalSummaryResponse(BaseModel):
    period: Literal["6m", "1y", "all"]
    concert_count: int
    unresolved_count: int
    locations: list[RegionalVisit]
