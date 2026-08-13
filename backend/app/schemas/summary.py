from pydantic import BaseModel
from typing import Literal


class ArtistVisitCount(BaseModel):
    # 관람 아티스트 한 명 + 관람 횟수
    name: str
    count: int


class SummaryResponse(BaseModel):
    # 기간별 결산 응답
    period: Literal["6m", "1y", "all"]
    concert_count: int
    song_count: int       # 실제 셋리스트 기준 합산
    total_spent: int
    top_genre: str | None
    artists: list[ArtistVisitCount]  # 관람 횟수 내림차순(동률이면 처음 본 순서)
    standing_count: int
    seated_count: int
    first_day_count: int
    last_day_count: int
