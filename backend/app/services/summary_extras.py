"""결산 부가 통계 - 티켓/아티스트/셋리스트에서 뽑는 값들(공연장, 요일, 지출, 예매처, 첫 관람, 곡 등).

get_summary가 이미 읽어온 티켓/셋리스트를 받아 계산만 하고, 표시 방식(몇 개를 보여줄지 등)은 앱이 정함.
"""
import re
from collections import Counter, defaultdict
from datetime import date, datetime, timedelta, timezone
from typing import Callable
from uuid import UUID

from fastapi import HTTPException
from sqlalchemy import func, select, tuple_
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from app.models.artist_normalization import CanonicalArtist
from app.models.concert import Concert
from app.models.lineup import ConcertLineup
from app.models.setlist import PreSetlist
from app.models.ticket import Ticket, TicketStatus
from app.services.setlist import resolve_performance_date

# 인터파크가 NOL로 이름이 바뀌어 같은 예매처가 두 표기로 들어옴
_TICKETING_SITE_ALIASES = {"nol ticket": "INTERPARK", "nol": "INTERPARK", "interpark": "INTERPARK"}

_TOP_VENUE_LIMIT = 3


# 개수들을 정수 퍼센트로 변환(최대잔여법). 같은 개수는 항상 같은 퍼센트로 보이게, 남은 몫은 같은
# 개수 묶음 전체에 줄 수 있을 때만 나눠서 1:1:1이 34/33/33 대신 33/33/33이 됨(이 경우 합이 99일 수 있음).
# 합계가 0이면 None
def percent_split(counts: list[int]) -> list[int] | None:
    total = sum(counts)
    if total == 0:
        return None
    floors = [c * 100 // total for c in counts]
    remaining = 100 - sum(floors)
    groups: dict[int, list[int]] = defaultdict(list)
    for i, c in enumerate(counts):
        groups[c].append(i)
    # 소수 부분이 큰 개수 묶음부터 몫을 줌 - 묶음이 통째로 못 받으면 건너뜀
    for count in sorted(groups, key=lambda c: -(c * 100 % total)):
        members = groups[count]
        if remaining >= len(members):
            for i in members:
                floors[i] += 1
            remaining -= len(members)
    return floors


# 한국 기준 현재 시각 - 공연/관람 날짜가 한국 날짜를 UTC 자정으로 저장한 값이라 "이번 달"도 한국 기준
def kst_now() -> datetime:
    return datetime.now(timezone(timedelta(hours=9)))


def attended_day(t: Ticket) -> date:
    return (t.attended_date or t.concert.start_date).date()


# 대소문자·공백 차이만 합쳐 같은 곡/아티스트로 봄
def _norm(text: str | None) -> str:
    return re.sub(r"\s+", " ", (text or "").strip().lower())


def empty_extras() -> dict:
    return {
        "top_venues": [], "weekday_counts": [0] * 7, "max_spend": None, "avg_ticket_price": None,
        "ticketing_sites": [], "ticketing_site_unknown_count": 0, "photo_count": 0, "diary_count": 0,
        "busiest_month": None, "monthly_stats": [], "top_spend_artist": None, "new_artist_count": 0, "new_artists": [],
        "new_artists_by_year": [],
        "origin_domestic_percent": None, "origin_foreign_percent": None, "origin_unknown_count": 0,
        "ticket_details": [],
        "most_heard_song": None, "rarest_song": None,
    }


# 월별 관람 수/지출 - 빈 달도 0으로 채워 그래프가 끊기지 않게 함. 범위는 선택 기간 시작 달(전체 기간이면
# 첫 관람 달)부터 이번 달(또는 마지막 관람 달)까지
def _monthly_stats(tickets: list[Ticket], period_start: datetime | None) -> list[dict]:
    if not tickets:
        return []
    counts: Counter = Counter()
    spent: Counter = Counter()
    for t in tickets:
        day = attended_day(t)
        counts[(day.year, day.month)] += 1
        spent[(day.year, day.month)] += t.price or 0
    first = min(counts)
    if period_start is not None:
        first = min(first, (period_start.year, period_start.month))
    now = kst_now()
    last = max(max(counts), (now.year, now.month))

    stats = []
    year, month = first
    while (year, month) <= last:
        stats.append({"month": f"{year}-{month:02d}", "concert_count": counts[(year, month)], "spent": spent[(year, month)]})
        year, month = (year + 1, 1) if month == 12 else (year, month + 1)
    return stats


# 티켓 필드만으로 계산되는 통계
def compute_ticket_extras(tickets: list[Ticket], period_start: datetime | None = None) -> dict:
    venues: Counter = Counter()
    weekdays = [0] * 7
    months: Counter = Counter()
    sites: Counter = Counter()
    site_unknown = photos = diaries = 0
    for t in tickets:
        concert = t.concert
        venue = (concert.venue or "").strip() if concert else ""
        if venue:
            venues[venue] += 1
        day = attended_day(t)
        weekdays[day.weekday()] += 1
        months[f"{day.year}-{day.month:02d}"] += 1

        site = (t.ticketing_site or "").strip()
        if site:
            sites[_TICKETING_SITE_ALIASES.get(site.lower(), site)] += 1
        else:
            site_unknown += 1

        if isinstance(t.concert_photo_urls, list):
            photos += len(t.concert_photo_urls)
        if t.diary and t.diary.strip():
            diaries += 1

    priced = [t for t in tickets if t.price]
    max_ticket = max(priced, key=lambda t: t.price) if priced else None  # 동률이면 먼저 본 공연
    site_percents = percent_split(list(sites.values()))
    percents = dict(zip(sites.keys(), site_percents)) if site_percents else {}
    site_items = sorted(sites.items(), key=lambda kv: -kv[1])
    busiest = max(months.items(), key=lambda kv: (kv[1], kv[0])) if months else None  # 동률이면 최근 달

    return {
        "top_venues": [{"name": n, "count": c} for n, c in venues.most_common(_TOP_VENUE_LIMIT)],
        "weekday_counts": weekdays,
        "max_spend": {"concert_name": max_ticket.concert.name, "price": max_ticket.price} if max_ticket else None,
        "avg_ticket_price": round(sum(t.price for t in priced) / len(priced)) if priced else None,
        "ticketing_sites": [{"name": n, "count": c, "percent": percents[n]} for n, c in site_items],
        "ticketing_site_unknown_count": site_unknown,
        "photo_count": photos,
        "diary_count": diaries,
        "busiest_month": {"month": busiest[0], "count": busiest[1]} if busiest else None,
        "monthly_stats": _monthly_stats(tickets, period_start),
    }


# 아티스트 단위 통계 - 관람한 날 라인업(artists_of)을 기준으로 함
async def compute_artist_extras(
    db: AsyncSession,
    user_id: UUID,
    period_start,
    tickets: list[Ticket],
    artists_of: Callable[[Ticket], list[str]],
) -> dict:
    ticket_artists = {t.id: artists_of(t) for t in tickets}

    # 가장 많이 쓴 아티스트 - 아티스트 1명인 공연의 티켓 가격만(페스티벌/합동은 가격을 나눌 근거가 없어 제외)
    spend: dict[str, int] = defaultdict(int)
    for t in tickets:
        names = ticket_artists[t.id]
        if len(names) == 1 and t.price:
            spend[names[0]] += t.price
    top_spend = max(spend.items(), key=lambda kv: kv[1]) if spend else None  # 동률이면 먼저 본 아티스트

    # 첫 관람 아티스트 - 선택 기간 이전 기록에 한 번도 안 나온 아티스트(전체 기간이면 전부)
    period_artists = list(dict.fromkeys(a for t in tickets for a in ticket_artists[t.id]))
    seen_before: set[str] = set()
    if period_start is not None and period_artists:
        earlier = (
            await db.execute(
                select(Ticket)
                .join(Concert, Ticket.concert_id == Concert.id)
                .where(
                    Ticket.user_id == user_id,
                    Ticket.status == TicketStatus.AFTER_CONCERT,
                    Ticket.concert_id.isnot(None),
                    func.coalesce(Ticket.attended_date, Concert.start_date) < period_start,
                )
                .options(joinedload(Ticket.concert))
            )
        ).scalars().all()
        seen_before = await _artists_of_tickets(db, list(earlier))
    new_artists = [a for a in period_artists if a not in seen_before]

    # 전체 기간은 "처음 본" 기준이 없어 전부 신규가 되므로, 대신 아티스트를 처음 본 해별로 묶어서 내림
    new_artists_by_year: list[dict] = []
    if period_start is None:
        first_year: dict[str, int] = {}
        for t in tickets:  # 관람일 순으로 정렬된 티켓
            for artist in ticket_artists[t.id]:
                first_year.setdefault(artist, attended_day(t).year)
        by_year: dict[int, list[str]] = defaultdict(list)
        for artist, year in first_year.items():
            by_year[year].append(artist)
        new_artists_by_year = [{"year": y, "artists": by_year[y]} for y in sorted(by_year)]

    # 내한 vs 국내 - 티켓 단위로 분류. MB 국가(KR이면 국내)를 우선 쓰고 라인업 다수결(동률이면 해외),
    # 국가를 아는 아티스트가 없으면 KOPIS visit으로 보조, 그것도 없으면 미분류
    countries = await _artist_countries(db, set(period_artists))
    domestic = foreign = unknown = 0
    origin_by_ticket: dict = {}  # 티켓별 분류(세부 목록용), 미분류는 넣지 않음
    for t in tickets:
        known = [countries[a] for a in ticket_artists[t.id] if a in countries]
        if known:
            foreign_n = sum(1 for c in known if c != "KR")
            kind = "foreign" if foreign_n >= len(known) - foreign_n else "domestic"
        elif t.concert and t.concert.visit is True:
            kind = "foreign"
        elif t.concert and t.concert.visit is False:
            kind = "domestic"
        else:
            unknown += 1
            continue
        origin_by_ticket[t.id] = kind
        if kind == "foreign":
            foreign += 1
        else:
            domestic += 1
    origin = percent_split([domestic, foreign])

    return {
        "top_spend_artist": {"name": top_spend[0], "amount": top_spend[1]} if top_spend else None,
        "new_artist_count": len(new_artists),
        "new_artists": new_artists,
        "new_artists_by_year": new_artists_by_year,
        "origin_domestic_percent": origin[0] if origin else None,
        "origin_foreign_percent": origin[1] if origin else None,
        "origin_unknown_count": unknown,
        "origin_by_ticket": origin_by_ticket,
    }


# 티켓들이 본 아티스트 이름 집합(관람일 라인업 우선, 없으면 공연 전체) - 이전 기록 확인용
async def _artists_of_tickets(db: AsyncSession, tickets: list[Ticket]) -> set[str]:
    keys: dict[UUID, tuple[UUID, date]] = {}
    for t in tickets:
        try:
            explicit = t.attended_date.date() if t.attended_date else None
            keys[t.id] = (t.concert_id, resolve_performance_date(t.concert, explicit))
        except HTTPException:
            continue
    lineup: dict[tuple[UUID, date], list[str]] = defaultdict(list)
    if keys:
        rows = await db.execute(
            select(ConcertLineup.concert_id, ConcertLineup.performance_date, ConcertLineup.artist).where(
                tuple_(ConcertLineup.concert_id, ConcertLineup.performance_date).in_(list(set(keys.values())))
            )
        )
        for concert_id, performance_date, artist in rows.all():
            lineup[(concert_id, performance_date)].append(artist)
    names: set[str] = set()
    for t in tickets:
        names.update(lineup.get(keys.get(t.id)) or (t.concert.artist_name if t.concert else None) or [])
    return names


# 아티스트 이름 -> MusicBrainz 국가 코드(국가를 아는 아티스트만)
async def _artist_countries(db: AsyncSession, names: set[str]) -> dict[str, str]:
    if not names:
        return {}
    rows = await db.execute(
        select(CanonicalArtist.canonical_name, CanonicalArtist.display_name, CanonicalArtist.mb_country).where(
            CanonicalArtist.mb_country.isnot(None),
            (CanonicalArtist.canonical_name.in_(names)) | (CanonicalArtist.display_name.in_(names)),
        )
    )
    result: dict[str, str] = {}
    for canonical_name, display_name, country in rows.all():
        for name in (canonical_name, display_name):
            if name in names:
                result[name] = country
    return result


# 셋리스트 기반 통계 - 가장 많이 들은 곡, 가장 희귀한 곡(예상 셋리 확률이 가장 낮은 곡)
async def compute_song_extras(
    db: AsyncSession,
    setlists: list,
    concert_by_key: dict[tuple[UUID, date], Concert],
    artists_by_key: dict[tuple[UUID, date], list[str]],
) -> dict:
    heard: Counter = Counter()
    labels: dict[tuple[str, str], tuple[str, str | None]] = {}
    real_by_key: dict[tuple[UUID, date], list[tuple[str, str | None, tuple[str, str]]]] = {}
    for setlist in setlists:
        key = (setlist.concert_id, setlist.performance_date)
        if key not in concert_by_key or not isinstance(setlist.songs, list):
            continue
        names = artists_by_key.get(key) or []
        default_artist = names[0] if len(names) == 1 else None
        songs = []
        for song in setlist.songs:
            name = (song.get("name") or "").strip() if isinstance(song, dict) else ""
            if not name:
                continue
            artist = song.get("artist") or default_artist or None
            song_id = (_norm(artist), _norm(name))
            heard[song_id] += 1
            labels.setdefault(song_id, (name, artist))
            songs.append((name, artist, song_id))
        real_by_key[key] = songs

    # 같은 곡을 한 번밖에 못 들었으면 "많이 들은 곡"이라 할 수 없어 비움
    most_heard = None
    if heard:
        song_id, count = max(heard.items(), key=lambda kv: kv[1])
        if count >= 2:
            name, artist = labels[song_id]
            most_heard = {"name": name, "artist": artist, "count": count}

    # 희귀한 곡 - 그 공연의 예상 셋리가 있을 때만 판단. 예상 목록에 없던 곡은 확률 0(가장 희귀)
    rarest = None
    concert_ids = {concert_by_key[k].id for k in real_by_key}
    pre_by_concert: dict[UUID, list] = {}
    if concert_ids:
        rows = await db.execute(
            select(PreSetlist.concert_id, PreSetlist.songs).where(PreSetlist.concert_id.in_(concert_ids))
        )
        pre_by_concert = {cid: songs for cid, songs in rows.all() if isinstance(songs, list)}
    for key, songs in real_by_key.items():
        concert = concert_by_key[key]
        pre = pre_by_concert.get(concert.id)
        if not pre:  # 예상 셋리가 없거나 아직 비어 있으면(생성 전 자리표시 행) 판단하지 않음
            continue
        by_artist_name: dict[tuple[str, str], float] = {}
        by_name: dict[str, float] = {}
        for p in pre:
            if not isinstance(p, dict) or not p.get("name"):
                continue
            prob = float(p.get("probability") or 0)
            by_artist_name[(_norm(p.get("artist")), _norm(p["name"]))] = prob
            by_name[_norm(p["name"])] = prob
        for name, artist, (artist_norm, name_norm) in songs:
            prob = by_artist_name.get((artist_norm, name_norm), by_name.get(name_norm, 0.0))
            if rarest is None or prob < rarest["probability"]:
                rarest = {
                    "name": name,
                    "artist": artist,
                    "concert_name": concert.name,
                    "probability": round(prob, 2),
                }

    return {"most_heard_song": most_heard, "rarest_song": rarest}
