from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.artist_normalization import ArtistAlias, CanonicalArtist
from app.models.concert import Concert

# 후보를 이 갯수만큼 SQL에서 가져온 뒤 파이썬에서 순위를 매겨 최종 limit만큼 자름
_CANDIDATE_FETCH_LIMIT = 200


# 아티스트 검색(팔로우용) - KOPIS 실시간 검색(공연 제목에 이름이 들어간 "예정" 공연만 찾김,
# concerts.py의 공연 검색과 별개) 대신 우리 DB의 Concert.artist_name을 직접 검색한다. 종료된
# 공연만 있는 아티스트도 찾을 수 있고(추천 기능과 동일한 소스), KOPIS API 장애와도 무관해짐.
# canonical_artists/artist_aliases가 있으면(정규화 완료분) 사진도 같이 붙여줌 - 아직 정규화
# 안 된 이름은 사진 없이 그대로 검색됨(2026-09-07)
async def search_artists(db: AsyncSession, query: str, limit: int = 30) -> list[dict]:
    q = query.strip()
    if not q:
        return []

    name_unnested = (
        select(func.unnest(Concert.artist_name).label("name")).where(Concert.artist_name != []).subquery()
    )
    result = await db.execute(
        select(name_unnested.c.name.distinct())
        .where(name_unnested.c.name.ilike(f"%{q}%"))
        .limit(_CANDIDATE_FETCH_LIMIT)
    )
    names = [n for n in result.scalars().all() if n]
    if not names:
        return []

    lowered_names = {n.lower() for n in names}
    image_result = await db.execute(
        select(ArtistAlias.alias_text, CanonicalArtist.profile_image_url)
        .join(CanonicalArtist, ArtistAlias.canonical_artist_id == CanonicalArtist.id)
        .where(func.lower(ArtistAlias.alias_text).in_(lowered_names))
    )
    images = {alias.lower(): url for alias, url in image_result.all() if url}

    # 질의어를 포함하는 이름을 앞으로, 그 안에서는 이름이 짧은 순
    # (기존 프론트 artist_search_service.dart의 정렬 기준과 동일)
    q_lower = q.lower()
    ranked = sorted(names, key=lambda n: (0 if q_lower in n.lower() else 1, len(n)))

    return [{"name": n, "profile_image_url": images.get(n.lower())} for n in ranked[:limit]]
