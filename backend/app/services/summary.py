from collections import Counter
from datetime import datetime, timedelta, timezone
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from app.models.ticket import Ticket, TicketStatus
from app.models.concert import Concert
from app.models.setlist import RealSetlist
from app.models.artist_genre import ArtistGenre

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
    # KOPIS의 Concert.genre는 이 앱 전체가 "대중음악" 한 값뿐이라 무의미해서 대신 씀
    # (Last.fm 아티스트 태그를 화이트리스트로 정규화해 캐싱해둔 값, services/lastfm.py 참고).
    # 아티스트 한 명이 여러 장르에 걸릴 수 있어서(예: 힙합+K-pop), 그 티켓에서 두 장르 모두에게
    # 표를 준다 - "1티켓 1표"가 아니라 "1티켓의 아티스트가 가진 장르 개수만큼 표"
    ticket_artist_names: set[str] = {
        artist
        for t in tickets
        if t.concert and t.concert.artist_name
        for artist in t.concert.artist_name
    }
    genres_by_artist: dict[str, list[str]] = {}
    if ticket_artist_names:
        genre_result = await db.execute(
            select(ArtistGenre.artist_name, ArtistGenre.genres).where(
                ArtistGenre.artist_name.in_(ticket_artist_names),
                ArtistGenre.genres.isnot(None),
            )
        )
        genres_by_artist = dict(genre_result.all())

    genre_counter: Counter = Counter()
    for t in tickets:
        if t.concert and t.concert.artist_name:
            for artist in t.concert.artist_name:
                for genre in genres_by_artist.get(artist, []):
                    genre_counter[genre] += 1
    top_genre = genre_counter.most_common(1)[0][0] if genre_counter else None

    # 관람 아티스트 (관람 횟수 내림차순, 동률이면 처음 본 순서 - "n회 관람")
    artist_counter: Counter = Counter()
    first_seen_order: list[str] = []
    seen: set[str] = set()
    for t in tickets:
        if t.concert and t.concert.artist_name:
            for a in t.concert.artist_name:
                artist_counter[a] += 1
                if a not in seen:
                    seen.add(a)
                    first_seen_order.append(a)

    artists = [
        {"name": a, "count": artist_counter[a]}
        for a in sorted(first_seen_order, key=lambda a: -artist_counter[a])
    ]

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
