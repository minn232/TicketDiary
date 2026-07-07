from collections import Counter
from datetime import datetime, timedelta, timezone
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from app.models.ticket import Ticket, TicketStatus
from app.models.concert import Concert
from app.models.setlist import RealSetlist

_STANDING_KEYWORDS = {"스탠딩", "standing", "ga", "입석", "floor"}


# 좌석 유형이 스탠딩인지 판별 (seat_type 키워드 기반)
def _is_standing(seat_type: str | None) -> bool:
    if not seat_type:
        return False
    return any(kw in seat_type.lower() for kw in _STANDING_KEYWORDS)


# 기간 필터 시작 시각 반환 (6m / 1y -> datetime, all -> None)
def _period_start(period: str) -> datetime | None:
    now = datetime.now(timezone.utc)
    if period == "6m":
        return now - timedelta(days=183)
    if period == "1y":
        return now - timedelta(days=365)
    return None


# 기간별 결산 통계 계산 (AFTER_CONCERT 티켓 기준)
async def get_summary(db: AsyncSession, user_id: UUID, period: str) -> dict:
    period_start = _period_start(period)

    query = (
        select(Ticket)
        .join(Concert, Ticket.concert_id == Concert.id)
        .where(
            Ticket.user_id == user_id,
            Ticket.status == TicketStatus.AFTER_CONCERT,
            Ticket.concert_id.isnot(None),
        )
        .options(joinedload(Ticket.concert))
    )
    if period_start:
        query = query.where(Concert.start_date >= period_start)

    result = await db.execute(query)
    tickets = list(result.scalars().all())

    if not tickets:
        return {
            "period": period,
            "concert_count": 0,
            "song_count": 0,
            "total_spent": 0,
            "top_genre": None,
            "artists": [],
            "standing_count": 0,
            "seated_count": 0,
            "first_day_count": 0,
            "last_day_count": 0,
        }

    concert_ids = [t.concert_id for t in tickets]

    setlist_result = await db.execute(
        select(RealSetlist).where(RealSetlist.concert_id.in_(concert_ids))
    )
    setlists = list(setlist_result.scalars().all())

    # 공연 수
    concert_count = len(tickets)

    # 소비 금액
    total_spent = sum(t.price for t in tickets if t.price is not None)

    # 들은 음악 수 (실제 셋리스트 기준)
    song_count = 0
    for setlist in setlists:
        if isinstance(setlist.songs, list):
            song_count += len(setlist.songs)

    # 선호 장르 (가장 많이 관람한 장르)
    genre_counter: Counter = Counter()
    for t in tickets:
        if t.concert and t.concert.genre:
            for g in t.concert.genre:
                genre_counter[g] += 1
    top_genre = genre_counter.most_common(1)[0][0] if genre_counter else None

    # 관람 아티스트 (중복 제거, 순서 유지)
    seen: set[str] = set()
    artists: list[str] = []
    for t in tickets:
        if t.concert and t.concert.artist_name:
            for a in t.concert.artist_name:
                if a not in seen:
                    seen.add(a)
                    artists.append(a)

    # 스탠딩 / 좌석 (seat_type이 있는 티켓만 집계)
    standing_count = sum(1 for t in tickets if _is_standing(t.seat_type))
    seated_count = sum(
        1 for t in tickets if t.seat_type and not _is_standing(t.seat_type)
    )

    # 첫콘 / 막콘
    first_day_count = sum(1 for t in tickets if t.is_first_day)
    last_day_count = sum(1 for t in tickets if t.is_last_day)

    return {
        "period": period,
        "concert_count": concert_count,
        "song_count": song_count,
        "total_spent": total_spent,
        "top_genre": top_genre,
        "artists": artists,
        "standing_count": standing_count,
        "seated_count": seated_count,
        "first_day_count": first_day_count,
        "last_day_count": last_day_count,
    }
