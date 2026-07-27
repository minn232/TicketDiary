from collections import defaultdict
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.artist_similarity import ArtistSimilarity
from app.models.concert import Concert
from app.models.social import ArtistFollow
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
    )
    return ranked[:limit]
