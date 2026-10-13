"""연결 카드 - 연결된 두 사람의 티켓/찜/셋리를 겹쳐 우리 사이 / 함께한 기록 / 다음에 같이를 계산

상대 단독 기록은 내리지 않고 겹치는 것과 집계만 내림 (예외: 상대가 공개를 켠 다음 공연 1개)
"""
import math
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import date, datetime, timezone
from uuid import UUID

from fastapi import HTTPException
from sqlalchemy import select, tuple_
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from app.models.concert import Concert
from app.models.connection import UserConnection
from app.models.lineup import ConcertLineup
from app.models.setlist import RealSetlist
from app.models.social import ArtistFollow, ConcertFollow
from app.models.ticket import Ticket, TicketStatus
from app.models.user import User
from app.schemas.connection import (
    CardConcert,
    CardHistory,
    CardNext,
    CardUs,
    Compatibility,
    ConnectionCardResponse,
    ConnectionPeer,
    InterestedConcert,
    SameConcertOtherDay,
    SharedSong,
    Taste,
)
from app.services.artist_genre import get_artist_genres
from app.services.setlist import resolve_performance_date
from app.services.summary_extras import _artist_countries, _norm, kst_now

_MAX_SHARED_SONGS = 3
_MAX_COMMON_ARTISTS = 5
_MAX_INTERESTED = 3
_MAX_SUGGESTIONS = 3
# 공통 장르 추천 후보로 훑어볼 가까운 다가오는 공연 수
_GENRE_SUGGESTION_POOL = 300
# 궁합 가중치 - 장르 분포가 취향을 가장 잘 드러내고, 겹치는 아티스트, 국내/내한 비율 순.
# 계산할 수 없는 항목은 빼고 남은 가중치로 다시 나눔
_WEIGHT_GENRE = 0.5
_WEIGHT_ARTIST = 0.35
_WEIGHT_ORIGIN = 0.15

# 취향 요약 - 국적/장르가 확인된 아티스트가 이보다 적으면 그 항목은 판단하지 않음
_MIN_TASTE_ARTISTS = 3
# 1위 국적 줄기가 이 비율 이상이면 단독 표시, 2·3위는 1위의 절반 이상일 때만 같이 셈
_ORIGIN_DOMINANT_SHARE = 0.6
_ORIGIN_RUNNER_UP_RATIO = 0.5
# 2위 장르가 1위의 이 비율 이상이면 같이 표시
_GENRE_RUNNER_UP_RATIO = 0.7
_ANGLO_COUNTRIES = {"US", "GB", "CA", "AU", "IE", "NZ"}


# 한 사람의 카드 계산 재료
@dataclass
class _Side:
    past: list[Ticket] = field(default_factory=list)
    upcoming: list[Ticket] = field(default_factory=list)
    # 관람일 키 (concert_id, performance_date) - 여러 날 공연인데 관람일을 모르면 없음
    keys: dict[UUID, tuple[UUID, date]] = field(default_factory=dict)
    attended_artists: set[str] = field(default_factory=set)
    followed_artists: set[str] = field(default_factory=set)
    followed_concert_ids: set[UUID] = field(default_factory=set)
    # 정규화한 (아티스트, 곡) -> 들은 공연(회차) 키들 / 표시용 이름
    songs: dict[tuple[str, str], set[tuple[UUID, date]]] = field(default_factory=lambda: defaultdict(set))
    song_labels: dict[tuple[str, str], tuple[str, str | None]] = field(default_factory=dict)

    @property
    def taste_artists(self) -> set[str]:
        return self.attended_artists | self.followed_artists


def _card_concert(concert: Concert, ticket: Ticket | None = None) -> CardConcert:
    return CardConcert(
        id=concert.id,
        name=concert.name,
        poster_url=concert.poster_url,
        venue=concert.venue,
        start_date=concert.start_date,
        end_date=concert.end_date,
        attended_date=ticket.attended_date.date() if ticket and ticket.attended_date else None,
        ticketing_date=concert.ticketing_date,
    )


def _performance_key(t: Ticket) -> tuple[UUID, date] | None:
    try:
        explicit = t.attended_date.date() if t.attended_date else None
        return t.concert_id, resolve_performance_date(t.concert, explicit)
    except HTTPException:
        return None


# 티켓·찜·관람한 날 라인업·셋리를 한 사람분 모음 (결산과 같은 기준: 관람한 날 라인업, 없으면 공연 전체)
async def _load_side(db: AsyncSession, user_id: UUID) -> _Side:
    side = _Side()
    today = kst_now().date()
    tickets = (
        await db.execute(
            select(Ticket)
            .where(Ticket.user_id == user_id, Ticket.concert_id.isnot(None))
            .options(joinedload(Ticket.concert))
        )
    ).scalars().all()
    for t in tickets:
        if t.status == TicketStatus.AFTER_CONCERT:
            side.past.append(t)
            key = _performance_key(t)
            if key:
                side.keys[t.id] = key
        elif t.concert.end_date.date() >= today:
            side.upcoming.append(t)
    side.upcoming.sort(key=lambda t: (t.attended_date or t.concert.start_date, t.concert.start_date))

    keys = list(set(side.keys.values()))
    lineup: dict[tuple[UUID, date], list[str]] = defaultdict(list)
    setlists = []
    if keys:
        rows = await db.execute(
            select(ConcertLineup.concert_id, ConcertLineup.performance_date, ConcertLineup.artist).where(
                tuple_(ConcertLineup.concert_id, ConcertLineup.performance_date).in_(keys)
            )
        )
        for concert_id, performance_date, artist in rows.all():
            lineup[(concert_id, performance_date)].append(artist)
        setlists = (
            await db.execute(
                select(RealSetlist).where(tuple_(RealSetlist.concert_id, RealSetlist.performance_date).in_(keys))
            )
        ).scalars().all()

    concert_by_key: dict[tuple[UUID, date], Concert] = {}
    for t in side.past:
        key = side.keys.get(t.id)
        artists = lineup.get(key) or t.concert.artist_name or []
        side.attended_artists.update(artists)
        if key:
            concert_by_key[key] = t.concert

    for setlist in setlists:
        key = (setlist.concert_id, setlist.performance_date)
        if key not in concert_by_key or not isinstance(setlist.songs, list):
            continue
        names = lineup.get(key) or concert_by_key[key].artist_name or []
        default_artist = names[0] if len(names) == 1 else None
        for song in setlist.songs:
            name = (song.get("name") or "").strip() if isinstance(song, dict) else ""
            if not name:
                continue
            artist = song.get("artist") or default_artist
            song_id = (_norm(artist), _norm(name))
            side.songs[song_id].add(key)
            side.song_labels.setdefault(song_id, (name, artist))

    artist_follow = (await db.execute(select(ArtistFollow).where(ArtistFollow.user_id == user_id))).scalar_one_or_none()
    if artist_follow:
        side.followed_artists = {a["artist_name"] for a in artist_follow.artists if a.get("artist_name")}
    concert_follow = (
        await db.execute(select(ConcertFollow).where(ConcertFollow.user_id == user_id))
    ).scalar_one_or_none()
    if concert_follow:
        side.followed_concert_ids = {UUID(c["concert_id"]) for c in concert_follow.concerts if c.get("concert_id")}
    return side


# 아티스트 집합의 장르 분포(아티스트마다 1표를 자기 장르들에 나눠 줌, 합 1로 정규화)
def _genre_distribution(artists: set[str], genres_by_artist: dict[str, list[str]]) -> dict[str, float]:
    votes: dict[str, float] = defaultdict(float)
    for artist in artists:
        genres = genres_by_artist.get(artist) or []
        for g in genres:
            votes[g] += 1 / len(genres)
    total = sum(votes.values())
    return {g: v / total for g, v in votes.items()} if total else {}


def _foreign_share(artists: set[str], countries: dict[str, str]) -> float | None:
    known = [countries[a] for a in artists if a in countries]
    if not known:
        return None
    return sum(1 for c in known if c != "KR") / len(known)


def _origin_group(country: str) -> str:
    if country == "KR":
        return "domestic"
    if country == "JP":
        return "japan"
    return "anglo" if country in _ANGLO_COUNTRIES else "other"


# 한 사람의 취향 요약 - 국적 큰 줄기(국내/일본/영미권/그 외) + 대표 장르. 둘 다 판단 못 하면 None
def _taste(artists: set[str], genres_by_artist: dict[str, list[str]], countries: dict[str, str]) -> Taste | None:
    origins: list[str] = []
    origin_mixed = False
    groups = Counter(_origin_group(countries[a]) for a in artists if a in countries)
    if sum(groups.values()) >= _MIN_TASTE_ARTISTS:
        ranked = groups.most_common()
        top_group, top_count = ranked[0]
        runners = [(g, n) for g, n in ranked[1:] if n >= top_count * _ORIGIN_RUNNER_UP_RATIO]
        if top_count / sum(groups.values()) >= _ORIGIN_DOMINANT_SHARE and not runners:
            origins = [top_group]
        elif len(runners) >= 2:
            origin_mixed = True
        else:
            origins = [top_group] + [g for g, _ in runners]

    genres: list[str] = []
    if sum(1 for a in artists if genres_by_artist.get(a)) >= _MIN_TASTE_ARTISTS:
        ranked_genres = sorted(_genre_distribution(artists, genres_by_artist).items(), key=lambda kv: (-kv[1], kv[0]))
        genres = [ranked_genres[0][0]]
        if len(ranked_genres) > 1 and ranked_genres[1][1] >= ranked_genres[0][1] * _GENRE_RUNNER_UP_RATIO:
            genres.append(ranked_genres[1][0])

    if not origins and not origin_mixed and not genres:
        return None
    return Taste(origins=origins, origin_mixed=origin_mixed, genres=genres)


def _compatibility(
    me: _Side, peer: _Side, common: set[str], genres_by_artist: dict[str, list[str]], countries: dict[str, str]
) -> Compatibility | None:
    mine, theirs = me.taste_artists, peer.taste_artists
    if not mine or not theirs:
        return None
    parts: list[tuple[float, float]] = []

    dist_me, dist_peer = _genre_distribution(mine, genres_by_artist), _genre_distribution(theirs, genres_by_artist)
    top_shared_genre = None
    if dist_me and dist_peer:
        dot = sum(v * dist_peer.get(g, 0) for g, v in dist_me.items())
        norm = math.sqrt(sum(v * v for v in dist_me.values())) * math.sqrt(sum(v * v for v in dist_peer.values()))
        parts.append((_WEIGHT_GENRE, dot / norm))
        shared = {g: min(v, dist_peer[g]) for g, v in dist_me.items() if g in dist_peer}
        top_shared_genre = max(shared, key=shared.get) if shared else None

    # 관람 수가 크게 다르면 합집합 기준으론 늘 낮게 나와서 작은 쪽 대비 겹친 비율로 봄
    parts.append((_WEIGHT_ARTIST, len(common) / min(len({_norm(a) for a in mine}), len({_norm(a) for a in theirs}))))

    share_me, share_peer = _foreign_share(mine, countries), _foreign_share(theirs, countries)
    if share_me is not None and share_peer is not None:
        parts.append((_WEIGHT_ORIGIN, 1 - abs(share_me - share_peer)))

    weight = sum(w for w, _ in parts)
    score = round(100 * sum(w * v for w, v in parts) / weight)
    return Compatibility(score=score, top_shared_genre=top_shared_genre, shared_artist_count=len(common))


def _common_artists(me: _Side, peer: _Side) -> tuple[set[str], list[str]]:
    peer_norm = {_norm(a) for a in peer.taste_artists}
    peer_attended_norm = {_norm(a) for a in peer.attended_artists}
    common_norm: set[str] = set()
    display: dict[str, str] = {}
    for a in sorted(me.taste_artists):
        n = _norm(a)
        if n in peer_norm:
            common_norm.add(n)
            display.setdefault(n, a)
    # 둘 다 실제로 본 아티스트를 먼저
    both_seen = {_norm(a) for a in me.attended_artists} & peer_attended_norm
    ordered = sorted(common_norm, key=lambda n: (n not in both_seen, display[n]))
    return common_norm, [display[n] for n in ordered]


def _history(me: _Side, peer: _Side) -> tuple[list[tuple[Ticket, Ticket]], list[SameConcertOtherDay]]:
    peer_by_concert: dict[UUID, Ticket] = {t.concert_id: t for t in peer.past}
    together: list[tuple[Ticket, Ticket]] = []
    other_days: list[SameConcertOtherDay] = []
    for t in me.past:
        p = peer_by_concert.get(t.concert_id)
        if p is None:
            continue
        my_key, peer_key = me.keys.get(t.id), peer.keys.get(p.id)
        # 한쪽이라도 관람일을 모르면 같은 날로 봄 (다른 날이라는 근거가 없음)
        if my_key and peer_key and my_key != peer_key:
            other_days.append(
                SameConcertOtherDay(concert=_card_concert(t.concert), my_date=my_key[1], peer_date=peer_key[1])
            )
        else:
            together.append((t, p))
    together.sort(key=lambda pair: pair[0].attended_date or pair[0].concert.start_date, reverse=True)
    return together, other_days


# 둘 다 라이브로 들은 곡 - 횟수는 들은 공연(회차) 수 (두 사람 횟수를 더하면 같이 본 공연 곡이 2번으로 세졌음)
def _shared_songs(me: _Side, peer: _Side) -> tuple[int, list[SharedSong]]:
    shared = [s for s in me.songs if s in peer.songs]
    times = {s: len(me.songs[s] | peer.songs[s]) for s in shared}
    shared.sort(key=lambda s: (-times[s], me.song_labels[s][0]))
    top = [
        SharedSong(name=me.song_labels[s][0], artist=me.song_labels[s][1], times=times[s])
        for s in shared[:_MAX_SHARED_SONGS]
    ]
    return len(shared), top


# 둘 다 좋아하는 장르(궁합의 top_shared_genre) 아티스트가 나오는 가까운 다가오는 공연
async def _genre_suggestions(db: AsyncSession, genre: str, exclude: set[UUID]) -> list[Concert]:
    rows = (
        await db.execute(
            select(Concert)
            .where(Concert.start_date >= datetime.now(timezone.utc))
            .order_by(Concert.start_date)
            .limit(_GENRE_SUGGESTION_POOL)
        )
    ).scalars().all()
    genres_by_artist = await get_artist_genres(db, {a for c in rows for a in c.artist_name or []})
    return [
        c
        for c in rows
        if c.id not in exclude and any(genre in genres_by_artist.get(a, []) for a in c.artist_name or [])
    ][:_MAX_SUGGESTIONS]


async def _next(
    db: AsyncSession,
    me: _Side,
    peer: _Side,
    peer_shares: bool,
    common_display: list[str],
    shared_genre: str | None,
) -> CardNext:
    my_next = me.upcoming[0] if me.upcoming else None
    peer_next = peer.upcoming[0] if peer.upcoming and peer_shares else None
    peer_ticket_ids = {t.concert_id for t in peer.upcoming}
    together_next = None
    if my_next and peer_next and my_next.concert_id == peer_next.concert_id:
        together_next, my_next, peer_next = my_next, None, None
    elif my_next and not peer_shares and my_next.concert_id in peer_ticket_ids:
        # 공개를 꺼도 둘 다 예매한 공연은 겹치는 기록이라 보여줌
        together_next, my_next = my_next, None

    # 둘 다 관심(예매 또는 찜) 있는 다가오는 공연
    my_status = {t.concert_id: "ticket" for t in me.upcoming}
    peer_status = {t.concert_id: "ticket" for t in peer.upcoming}
    for cid in me.followed_concert_ids:
        my_status.setdefault(cid, "follow")
    for cid in peer.followed_concert_ids:
        peer_status.setdefault(cid, "follow")
    both_ids = set(my_status) & set(peer_status)
    if together_next:
        both_ids.discard(together_next.concert_id)
    today = kst_now().date()
    interested: list[InterestedConcert] = []
    if both_ids:
        concerts = (await db.execute(select(Concert).where(Concert.id.in_(both_ids)))).scalars().all()
        upcoming = sorted((c for c in concerts if c.end_date.date() >= today), key=lambda c: c.start_date)
        interested = [
            InterestedConcert(concert=_card_concert(c), my_status=my_status[c.id], peer_status=peer_status[c.id])
            for c in upcoming[:_MAX_INTERESTED]
        ]

    # 추천은 관심 공연과 별개로 항상 - 공통 아티스트의 다가오는 공연을 먼저, 남는 자리는 둘 다 좋아하는
    # 장르 공연으로 채움. 둘 중 누가 이미 예매/찜한 공연은 뺌 (상대 단독 기록은 안 드러남)
    exclude = set(my_status) | set(peer_status)
    picked: list[Concert] = []
    if common_display:
        rows = (
            await db.execute(
                select(Concert)
                .where(Concert.artist_name.overlap(common_display), Concert.start_date >= datetime.now(timezone.utc))
                .order_by(Concert.start_date)
                .limit(_MAX_SUGGESTIONS + len(exclude))
            )
        ).scalars().all()
        picked = [c for c in rows if c.id not in exclude][:_MAX_SUGGESTIONS]
    by_artist = len(picked)
    if len(picked) < _MAX_SUGGESTIONS and shared_genre:
        exclude |= {c.id for c in picked}
        picked += (await _genre_suggestions(db, shared_genre, exclude))[: _MAX_SUGGESTIONS - len(picked)]
    suggestions = [_card_concert(c) for c in picked]
    suggestion_basis = (
        None
        if not picked
        else "artist"
        if by_artist == len(picked)
        else "genre"
        if by_artist == 0
        else "mixed"
    )

    return CardNext(
        my_next=_card_concert(my_next.concert, my_next) if my_next else None,
        peer_next=_card_concert(peer_next.concert, peer_next) if peer_next else None,
        together_next=_card_concert(together_next.concert, together_next) if together_next else None,
        peer_next_hidden=not peer_shares,
        both_interested=interested,
        suggestions=suggestions,
        suggestion_basis=suggestion_basis,
    )


# 연결된 상대와의 카드 - 연결된 사이가 아니면 404
async def get_connection_card(db: AsyncSession, user_id: UUID, peer_user_id: UUID) -> ConnectionCardResponse:
    user_a_id, user_b_id = sorted([user_id, peer_user_id], key=str)
    connection = (
        await db.execute(
            select(UserConnection).where(
                UserConnection.user_a_id == user_a_id,
                UserConnection.user_b_id == user_b_id,
                UserConnection.connected_at.isnot(None),
            )
        )
    ).scalar_one_or_none()
    if connection is None:
        raise HTTPException(status_code=404, detail="연결된 상대가 아닙니다.")
    peer_user = await db.get(User, peer_user_id)

    me, peer = await _load_side(db, user_id), await _load_side(db, peer_user_id)
    common_norm, common_display = _common_artists(me, peer)
    together, other_days = _history(me, peer)
    shared_song_count, shared_songs = _shared_songs(me, peer)
    all_artists = me.taste_artists | peer.taste_artists
    genres_by_artist = await get_artist_genres(db, all_artists)
    countries = await _artist_countries(db, all_artists)
    compatibility = _compatibility(me, peer, common_norm, genres_by_artist, countries)

    return ConnectionCardResponse(
        peer=ConnectionPeer(
            user_id=peer_user.id, nickname=peer_user.nickname, profile_image_url=peer_user.profile_image_url
        ),
        connected_at=connection.connected_at,
        last_met_at=connection.last_met_at,
        us=CardUs(
            together_count=len(together),
            latest_together_poster_url=together[0][0].concert.poster_url if together else None,
            compatibility=compatibility,
            common_artists=common_display[:_MAX_COMMON_ARTISTS],
            my_taste=_taste(me.taste_artists, genres_by_artist, countries),
            peer_taste=_taste(peer.taste_artists, genres_by_artist, countries),
        ),
        history=CardHistory(
            together_concerts=[_card_concert(t.concert, t) for t, _ in together],
            shared_song_count=shared_song_count,
            shared_songs=shared_songs,
            same_concert_other_days=other_days,
        ),
        next=await _next(
            db,
            me,
            peer,
            peer_user.share_next_concert,
            common_display,
            compatibility.top_shared_genre if compatibility else None,
        ),
    )
