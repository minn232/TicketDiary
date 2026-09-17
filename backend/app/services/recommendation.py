from collections import defaultdict
from datetime import datetime, timezone
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.artist_normalization import ArtistAlias, CanonicalArtist
from app.models.artist_similarity import ArtistSimilarity
from app.models.concert import Concert
from app.models.social import ArtistFollow, ConcertFollow
from app.models.ticket import Ticket


# 추천의 씨앗이 될 아티스트 이름 목록. 팔로우한 아티스트가 없으면(콜드스타트)
# 티켓 등록 이력(실제 관람한 공연)의 아티스트로 대체
async def _get_seed_artist_names(db: AsyncSession, user_id: UUID) -> set[str]:
    follow_result = await db.execute(select(ArtistFollow.artists).where(ArtistFollow.user_id == user_id))
    follow_artists = follow_result.scalar_one_or_none() or []
    names = {entry.get("artist_name", "").strip() for entry in follow_artists if entry.get("artist_name")}
    if names:
        return names

    ticket_result = await db.execute(
        select(Concert.artist_name).join(Ticket, Ticket.concert_id == Concert.id).where(Ticket.user_id == user_id)
    )
    for arr in ticket_result.scalars().all():
        names.update(name.strip() for name in (arr or []) if name and name.strip())
    return names


# 유저가 팔로우(또는 관람)한 아티스트들과 Last.fm 기준 유사한 아티스트를 점수순으로 추천
# - 이미 팔로우 중인 아티스트는 제외
# - 이 앱에 실제로 공연이 등록된 아티스트로만 필터링 (추천해도 볼 공연이 없으면 무의미)
async def get_artist_recommendations(db: AsyncSession, user_id: UUID, limit: int = 30) -> list[dict]:
    seed_names = await _get_seed_artist_names(db, user_id)
    if not seed_names:
        return []
    seed_names_lower = {name.lower() for name in seed_names}

    similarity_result = await db.execute(
        select(ArtistSimilarity.similar_artist_name, ArtistSimilarity.match_score).where(
            func.lower(ArtistSimilarity.artist_name).in_(seed_names_lower)
        )
    )

    # 대소문자가 다른 동일 아티스트(예: "BTS" vs "bts")가 서로 다른 키로 남아 추천 목록에
    # 중복으로 뜨지 않도록, 점수 합산 단계부터 소문자 키로 통일
    scores: dict[str, float] = defaultdict(float)
    for name, score in similarity_result.all():
        key = name.lower()
        if key not in seed_names_lower:
            scores[key] += score
    if not scores:
        return []

    # scores.keys()에 해당하는 후보 아티스트명만 SQL에서 걸러서 가져옴 - 공연 테이블 전체를
    # 파이썬으로 로드하지 않음 (공연 수가 많아져도 이 쿼리 비용은 후보 개수만큼만 늘어남)
    name_unnested = select(func.unnest(Concert.artist_name).label("name")).where(
        Concert.artist_name != []
    ).subquery()
    concert_result = await db.execute(
        select(name_unnested.c.name.distinct()).where(func.lower(name_unnested.c.name).in_(scores.keys()))
    )
    available_names: dict[str, str] = {}
    for name in concert_result.scalars().all():
        if name:
            available_names.setdefault(name.lower(), name)

    ranked = sorted(
        (
            {"artist_name": available_names[key], "score": score}
            for key, score in scores.items()
            if key in available_names
        ),
        key=lambda entry: entry["score"],
        reverse=True,
    )[:limit]

    await _attach_profile_images(db, ranked)
    return ranked


# 추천 목록에 사진을 채워줌(원래 이름/score만 반환해서 그리드에 늘 플레이스홀더만 뜨던 버그) -
# artist_search.py와 같은 소스(CanonicalArtist)를 canonical_name/alias 양쪽으로 대조.
# 추천 이름은 정규화 전 원본 문자열일 수 있어 별칭까지 맞춰봐야 매치율이 높음.
async def _attach_profile_images(db: AsyncSession, entries: list[dict]) -> None:
    if not entries:
        return
    names_lower = {entry["artist_name"].lower() for entry in entries}

    canonical_result = await db.execute(
        select(CanonicalArtist).where(func.lower(CanonicalArtist.canonical_name).in_(names_lower))
    )
    photo_by_name_lower: dict[str, str | None] = {
        c.canonical_name.lower(): c.profile_image_url for c in canonical_result.scalars().all()
    }

    alias_result = await db.execute(
        select(ArtistAlias.alias_text, CanonicalArtist.profile_image_url)
        .join(CanonicalArtist, ArtistAlias.canonical_artist_id == CanonicalArtist.id)
        .where(func.lower(ArtistAlias.alias_text).in_(names_lower))
    )
    for alias_text, photo_url in alias_result.all():
        photo_by_name_lower.setdefault(alias_text.lower(), photo_url)

    for entry in entries:
        entry["profile_image_url"] = photo_by_name_lower.get(entry["artist_name"].lower())


# 찜 공연 추천 - 아티스트 추천과 달리 팔로우/티켓 이력이 없는 완전 신규 유저도 바로 볼 수
# 있어야 해서(검색창을 처음 열었을 때부터 뭔가 보여주려는 목적), Last.fm 유사도 같은
# 개인화 신호 대신 "이 앱에서 얼마나 많이 찜/티켓 등록됐는지"(인기도)로 순위를 매김.
# 이미 자기가 찜했거나 티켓 등록한 공연은 추천에서 제외(볼 필요 없는 걸 또 보여줄 필요 없음)
async def get_concert_recommendations(db: AsyncSession, user_id: UUID, limit: int = 30) -> list[Concert]:
    now = datetime.now(timezone.utc)

    own_follow_result = await db.execute(
        select(ConcertFollow.concerts).where(ConcertFollow.user_id == user_id)
    )
    own_concerts = own_follow_result.scalar_one_or_none() or []
    excluded_ids = {c.get("concert_id") for c in own_concerts if c.get("concert_id")}

    own_ticket_result = await db.execute(select(Ticket.concert_id).where(Ticket.user_id == user_id))
    excluded_ids.update(str(cid) for cid in own_ticket_result.scalars().all() if cid)

    # 찜 집계는 JSONB 배열이라 관계형 GROUP BY가 안 되므로 파이썬에서 직접 카운트.
    # (jsonb_array_length > 0 조건으로 빈 배열인 유저는 미리 걸러 스캔량을 줄임 -
    # _build_follow_index/kopis.py와 동일한 패턴)
    follow_rows = await db.execute(
        select(ConcertFollow.concerts).where(func.jsonb_array_length(ConcertFollow.concerts) > 0)
    )
    scores: dict[str, int] = defaultdict(int)
    for concerts in follow_rows.scalars().all():
        for entry in concerts or []:
            concert_id = entry.get("concert_id")
            if concert_id:
                scores[concert_id] += 1

    # 티켓 등록 수는 관계형 컬럼(concert_id FK)이라 SQL에서 바로 집계
    ticket_count_result = await db.execute(
        select(Ticket.concert_id, func.count()).where(Ticket.concert_id.isnot(None)).group_by(Ticket.concert_id)
    )
    for concert_id, count in ticket_count_result.all():
        scores[str(concert_id)] += count

    candidate_ids = [cid for cid in scores if cid not in excluded_ids]
    if not candidate_ids:
        return []

    ranked_ids = sorted(candidate_ids, key=lambda cid: scores[cid], reverse=True)

    # 상위 후보를 넉넉히(limit의 3배) 조회 - 그중 이미 종료된 공연을 걸러내고도 limit을 채우기 위함
    top_ids: list[UUID] = []
    for cid in ranked_ids[: limit * 3]:
        try:
            top_ids.append(UUID(cid))
        except ValueError:
            continue

    concert_result = await db.execute(
        select(Concert).where(Concert.id.in_(top_ids), Concert.end_date > now)
    )
    concerts_by_id = {str(c.id): c for c in concert_result.scalars().all()}

    ordered = [concerts_by_id[cid] for cid in ranked_ids if cid in concerts_by_id]
    return ordered[:limit]
