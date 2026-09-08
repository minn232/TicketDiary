from datetime import datetime, timezone

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.artist_normalization import ArtistAlias, CanonicalArtist
from app.models.concert import Concert
from app.services.text_utils import min_len_ok

_RESULT_LIMIT = 30


# 찜 공연 검색(DB 기준, KOPIS 실시간 호출 없음 - 타이핑마다 즉시 응답하기 위함).
# 종료된 공연은 찜할 의미가 없어 제외(end_date > now). 최대 하루 지연(KOPIS 동기화 배치 주기)은 감수.
#
# 매치 대상 3가지:
#   1) 공연명(Concert.name)
#   2) 아티스트명 원문(Concert.artist_name - 이미 정규화된 표기도 포함)
#   3) 아티스트 별칭/원어 표기 - 검색어가 CanonicalArtist.canonical_name/ArtistAlias.alias_text에
#      걸리면, 그 아티스트 "자신"의 표기(canonical_name + 자기 alias들)가 실제로 등장하는 공연만 추가.
#      artist_search.py의 search_artists()와 달리 멤버->그룹(ArtistGroupMembership) 확장은 절대
#      하지 않음 - 밴드 멤버 이름으로 검색해도 그 멤버가 속한 그룹의 공연은 나오면 안 되기 때문
#      (2026-09-09 결정). 그래서 "블랙핑크"(별칭) 검색은 artist_name에 "BLACKPINK"가 들어간 공연을
#      찾지만, "지수"(멤버) 검색은 지수 자신의 이름이 literally 들어간 공연만 찾고 BLACKPINK
#      공연으로는 확장되지 않는다.
async def search_concerts_db(db: AsyncSession, query: str, limit: int = _RESULT_LIMIT) -> list[Concert]:
    q = query.strip()
    if not q or not min_len_ok(q):
        return []

    now = datetime.now(timezone.utc)
    pattern = f"%{q}%"

    name_unnested = (
        select(Concert.id.label("concert_id"), func.unnest(Concert.artist_name).label("name"))
        .where(Concert.artist_name != [])
        .subquery()
    )

    # 1) 공연명 직접 매치
    title_result = await db.execute(
        select(Concert.id).where(Concert.name.ilike(pattern), Concert.end_date > now)
    )
    matched_ids: set = set(title_result.scalars().all())

    # 2) 아티스트명 원문 직접 매치
    artist_result = await db.execute(
        select(name_unnested.c.concert_id.distinct())
        .join(Concert, Concert.id == name_unnested.c.concert_id)
        .where(name_unnested.c.name.ilike(pattern), Concert.end_date > now)
    )
    matched_ids.update(artist_result.scalars().all())

    # 3) 별칭/원어 표기 매치 (멤버->그룹 확장 없이, 자기 표기가 등장하는 공연만)
    canonical_result = await db.execute(
        select(CanonicalArtist).where(CanonicalArtist.canonical_name.ilike(pattern))
    )
    alias_result = await db.execute(
        select(CanonicalArtist)
        .join(ArtistAlias, ArtistAlias.canonical_artist_id == CanonicalArtist.id)
        .where(ArtistAlias.alias_text.ilike(pattern))
    )
    canonicals = {c.id: c for c in canonical_result.scalars().all()}
    for c in alias_result.scalars().all():
        canonicals.setdefault(c.id, c)

    if canonicals:
        own_names_lower = {c.canonical_name.strip().lower() for c in canonicals.values() if c.canonical_name}
        own_alias_rows = await db.execute(
            select(ArtistAlias.alias_text).where(ArtistAlias.canonical_artist_id.in_(canonicals.keys()))
        )
        own_names_lower |= {a.strip().lower() for a in own_alias_rows.scalars().all() if a}

        if own_names_lower:
            alias_match_result = await db.execute(
                select(name_unnested.c.concert_id.distinct())
                .join(Concert, Concert.id == name_unnested.c.concert_id)
                .where(func.lower(name_unnested.c.name).in_(own_names_lower), Concert.end_date > now)
            )
            matched_ids.update(alias_match_result.scalars().all())

    if not matched_ids:
        return []

    # 임박한 공연부터 - 찜 후보로는 그게 더 유용함
    result = await db.execute(
        select(Concert).where(Concert.id.in_(matched_ids)).order_by(Concert.start_date)
    )
    return list(result.scalars().all())[:limit]
