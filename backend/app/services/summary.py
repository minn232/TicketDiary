import re
from collections import Counter, defaultdict
from fractions import Fraction
from datetime import date, datetime, timedelta, timezone
from uuid import UUID

from fastapi import HTTPException
from sqlalchemy import func, select, tuple_
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from app.models.ticket import Ticket, TicketStatus
from app.models.concert import Concert, EventType
from app.models.lineup import ConcertLineup
from app.models.setlist import RealSetlist
from app.services.artist_genre import get_artist_genres
from app.services.setlist import resolve_performance_date
from app.services.summary_extras import (
    compute_artist_extras,
    compute_song_extras,
    compute_ticket_extras,
    empty_extras,
    percent_split as _percent_split,
)

# 장르가 잡힌 티켓이 이 비율 미만이면 선호 장르를 단정하지 않음
_MIN_GENRE_COVERAGE = 0.5

# 셋리스트 없는 공연의 곡 수 어림용 곡당 분(멘트/앵콜 포함). 솔로 7건 중앙값이라 표본이 작음
_MINUTES_PER_SONG = 5

# 이보다 긴 러닝타임은 시리즈/하루 종일 일정이 섞인 값이라 관람 시간 계산에서 제외(워터밤처럼 SOLO로 분류된 것 포함)
_MAX_RUNTIME_MINUTES = 300

# ga/floor는 Garden, Gallery에 부분 일치하지 않게 영문자 경계로 매칭, 플로어석/Floor seat는 지정석이라 제외
_STANDING_PATTERN = re.compile(
    r"스탠딩|입석|standing|スタンディング"
    r"|(?<![a-z])ga(?![a-z])"
    r"|(?:(?<![a-z])floor(?![a-z])|플로어)(?!\s*(?:석|좌석|seat))"
)


# 좌석 유형이 스탠딩인지 판별 (seat_type 키워드 기반)
def _is_standing(seat_type: str | None) -> bool:
    if not seat_type:
        return False
    return _STANDING_PATTERN.search(seat_type.lower()) is not None


# 결산에 쓸 수 있는 러닝타임(분) - 솔로 공연이고 값이 있으며 상한 이내일 때만, 아니면 None
def _usable_runtime(concert: Concert | None) -> int | None:
    if concert is None or concert.event_type != EventType.SOLO.value:
        return None
    minutes = concert.runtime_minutes
    return minutes if minutes and minutes <= _MAX_RUNTIME_MINUTES else None


# 티켓의 관람일 기준 날짜 - 기간 필터/지역 결산과 같은 기준(관람일 우선, 없으면 공연 시작일)
def _attended_at():
    return func.coalesce(Ticket.attended_date, Concert.start_date)


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
        # 동률 아티스트의 "처음 본 순서"가 호출마다 달라지지 않게 관람일 순으로 고정
        .order_by(_attended_at(), Concert.start_date, Ticket.id)
    )
    if period_start:
        query = query.where(_attended_at() >= period_start)

    result = await db.execute(query)
    tickets = list(result.scalars().all())

    if not tickets:
        return {
            "period": period,
            "concert_count": 0,
            "song_count": 0,
            "song_count_estimated": 0,
            "total_runtime_minutes": 0,
            "runtime_missing_count": 0,
            "total_spent": 0,
            "top_genre": None,
            "top_genres": [],
            "artists": [],
            "standing_count": 0,
            "seated_count": 0,
            "first_day_count": 0,
            "last_day_count": 0,
            "standing_percent": None,
            "seated_percent": None,
            "first_day_percent": None,
            "last_day_percent": None,
            **empty_extras(),
        }

    # 관람한 날의 셋리만 셈 - 여러 날 공연은 날짜별 셋리가 따로 있어서 다 더하면 안 간 날 곡까지 들어감.
    # 관람일 모르는 여러 날 공연은 날짜를 추측하지 않고 뺌(resolve_performance_date와 같은 기준)
    performance_keys: set[tuple[UUID, date]] = set()
    ticket_keys: dict[UUID, tuple[UUID, date]] = {}
    for t in tickets:
        try:
            explicit_date = t.attended_date.date() if t.attended_date else None
            key = (t.concert_id, resolve_performance_date(t.concert, explicit_date))
        except HTTPException:
            continue
        performance_keys.add(key)
        ticket_keys[t.id] = key

    setlists = []
    if performance_keys:
        setlist_result = await db.execute(
            select(RealSetlist).where(
                tuple_(RealSetlist.concert_id, RealSetlist.performance_date).in_(list(performance_keys))
            )
        )
        setlists = list(setlist_result.scalars().all())

    # 관람한 날 배정된 라인업 - 페스티벌은 안 간 날 아티스트까지 "관람"으로 세지 않게 좁힘.
    # 관람일을 모르거나 그 날짜 배정이 없으면 공연 전체 아티스트로 폴백(setlist와 같은 폴백)
    lineup_by_key: dict[tuple[UUID, date], list[str]] = defaultdict(list)
    if performance_keys:
        lineup_result = await db.execute(
            select(ConcertLineup.concert_id, ConcertLineup.performance_date, ConcertLineup.artist).where(
                tuple_(ConcertLineup.concert_id, ConcertLineup.performance_date).in_(list(performance_keys))
            )
        )
        for concert_id, performance_date, artist in lineup_result.all():
            lineup_by_key[(concert_id, performance_date)].append(artist)

    def attended_artists(t: Ticket) -> list[str]:
        if not t.concert:
            return []
        return lineup_by_key.get(ticket_keys.get(t.id)) or t.concert.artist_name or []

    # 공연 수
    concert_count = len(tickets)

    # 소비 금액
    total_spent = sum(t.price for t in tickets if t.price is not None)

    # 들은 음악 수 (실제 셋리스트 기준)
    song_count = 0
    keys_with_songs: set[tuple[UUID, date]] = set()
    for setlist in setlists:
        if isinstance(setlist.songs, list) and setlist.songs:
            song_count += len(setlist.songs)
            keys_with_songs.add((setlist.concert_id, setlist.performance_date))

    # 셋리스트 없는 관람일의 곡 수 어림치(러닝타임 ÷ 곡당 분). song_count와 섞지 않고 따로 내려 앱이
    # 합칠지 정함. 페스티벌은 러닝타임이 하루 전체 일정이라 제외
    concert_by_key = {ticket_keys[t.id]: t.concert for t in tickets if t.id in ticket_keys and t.concert}
    song_count_estimated = sum(
        round(_usable_runtime(c) / _MINUTES_PER_SONG)
        for key, c in concert_by_key.items()
        if key not in keys_with_songs and _usable_runtime(c)
    )

    # 총 관람 시간(분) - 공연 러닝타임 합(인터미션 포함 가능). 페스티벌/러닝타임 모르거나 상한 초과
    # 공연은 빼고 그 티켓 수를 runtime_missing_count로 알림
    total_runtime_minutes = 0
    runtime_missing_count = 0
    for t in tickets:
        runtime = _usable_runtime(t.concert)
        if runtime:
            total_runtime_minutes += runtime
        else:
            runtime_missing_count += 1

    # 선호 장르 - KOPIS Concert.genre는 전부 "대중음악"이라 MB/Last.fm 장르를 씀. 티켓 1장이 1표이고
    # 아티스트 장르 비율대로 나눠 가져 큰 페스티벌이 표를 몰아가지 못함. 동률은 공동 1위를 모두 내리며
    # 분수로 계산해 부동소수점 오차로 동률이 깨지지 않게 함
    ticket_artist_names: set[str] = {artist for t in tickets for artist in attended_artists(t)}
    genres_by_artist = await get_artist_genres(db, ticket_artist_names)

    genre_votes: dict[str, Fraction] = {}
    classified_tickets = 0
    for t in tickets:
        ticket_genres = Counter(
            genre for artist in attended_artists(t) for genre in genres_by_artist.get(artist, [])
        )
        total = sum(ticket_genres.values())
        if not total:
            continue
        classified_tickets += 1
        for genre, n in ticket_genres.items():
            genre_votes[genre] = genre_votes.get(genre, Fraction(0)) + Fraction(n, total)

    top_genres: list[str] = []
    if genre_votes and classified_tickets / len(tickets) >= _MIN_GENRE_COVERAGE:
        best = max(genre_votes.values())
        top_genres = [g for g, v in genre_votes.items() if v == best]
    top_genre = top_genres[0] if top_genres else None

    # 관람 아티스트 (관람 횟수 내림차순, 동률이면 처음 본 순서 - "n회 관람")
    artist_counter: Counter = Counter()
    first_seen_order: list[str] = []
    seen: set[str] = set()
    for t in tickets:
        for a in attended_artists(t):
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

    # 스탠딩/좌석 선호 - seat_type으로 확실히 판별된 티켓끼리만 합 100%
    seat_split = _percent_split([standing_count, seated_count])

    # 첫콘 / 막콘
    first_day_count = sum(1 for t in tickets if t.is_first_day)
    last_day_count = sum(1 for t in tickets if t.is_last_day)

    # 첫콘/막콘 선호 - 공연이 정확히 이틀인 공연의 티켓 중 첫날/마지막날로 판정된 것끼리만 합 100%
    # (사흘 이상 공연은 가운데 날이 있어 "첫콘 아니면 막콘"이 성립하지 않아 제외)
    two_day = [
        t for t in tickets
        if t.concert and (t.concert.end_date.date() - t.concert.start_date.date()).days == 1
    ]
    day_split = _percent_split(
        [sum(1 for t in two_day if t.is_first_day), sum(1 for t in two_day if t.is_last_day)]
    )

    # 부가 통계 - 티켓 필드 / 아티스트 이력 / 셋리스트 기반(같은 관람일 라인업 기준)
    artists_by_key: dict[tuple[UUID, date], list[str]] = {}
    for t in tickets:
        if t.id in ticket_keys:
            artists_by_key.setdefault(ticket_keys[t.id], attended_artists(t))
    extras = {
        **compute_ticket_extras(tickets, period_start),
        **await compute_artist_extras(db, user_id, period_start, tickets, attended_artists),
        **await compute_song_extras(db, setlists, concert_by_key, artists_by_key),
    }

    return {
        "period": period,
        "concert_count": concert_count,
        "song_count": song_count,
        "song_count_estimated": song_count_estimated,
        "total_runtime_minutes": total_runtime_minutes,
        "runtime_missing_count": runtime_missing_count,
        "total_spent": total_spent,
        "top_genre": top_genre,
        "top_genres": top_genres,
        "artists": artists,
        "standing_count": standing_count,
        "seated_count": seated_count,
        "first_day_count": first_day_count,
        "last_day_count": last_day_count,
        "standing_percent": seat_split[0] if seat_split else None,
        "seated_percent": seat_split[1] if seat_split else None,
        "first_day_percent": day_split[0] if day_split else None,
        "last_day_percent": day_split[1] if day_split else None,
        **extras,
    }
