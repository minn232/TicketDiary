from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.artist_normalization import ArtistAlias, ArtistGroupMembership, CanonicalArtist
from app.models.concert import Concert

# 후보를 이 갯수만큼 SQL에서 가져온 뒤 파이썬에서 순위를 매겨 최종 limit만큼 자름
_CANDIDATE_FETCH_LIMIT = 200


def _display_value(canonical: CanonicalArtist) -> str:
    return canonical.display_name or canonical.canonical_name


# 아티스트 검색(팔로우용) - KOPIS 실시간 검색(예정 공연만 찾김) 대신 우리 DB를 직접 검색.
# Concert.artist_name(원본, 미정규화까지 커버) + canonical_name/alias(그룹-멤버 관계로만
# 존재하는 아티스트도 찾음) 세 소스를 합침. 멤버-그룹 노출 규칙은 아래 final_ids 참고.
async def search_artists(db: AsyncSession, query: str, limit: int = 30) -> list[dict]:
    q = query.strip()
    if not q:
        return []

    name_unnested = (
        select(func.unnest(Concert.artist_name).label("name")).where(Concert.artist_name != []).subquery()
    )
    raw_result = await db.execute(
        select(name_unnested.c.name.distinct())
        .where(name_unnested.c.name.ilike(f"%{q}%"))
        .limit(_CANDIDATE_FETCH_LIMIT)
    )
    raw_names = [n for n in raw_result.scalars().all() if n]

    canonical_result = await db.execute(
        select(CanonicalArtist).where(CanonicalArtist.canonical_name.ilike(f"%{q}%")).limit(_CANDIDATE_FETCH_LIMIT)
    )
    alias_result = await db.execute(
        select(CanonicalArtist)
        .join(ArtistAlias, ArtistAlias.canonical_artist_id == CanonicalArtist.id)
        .where(ArtistAlias.alias_text.ilike(f"%{q}%"))
        .limit(_CANDIDATE_FETCH_LIMIT)
    )
    canonicals: dict = {c.id: c for c in canonical_result.scalars().all()}
    for c in alias_result.scalars().all():
        canonicals.setdefault(c.id, c)

    # 원본 텍스트로 찾은 이름 중 이미 정규화된 건(별칭/이름 검색에서 안 걸렸어도) canonical로
    # 합치고, 못 찾은 것만 "아직 정규화 안 된 원문 그대로"로 따로 둔다
    unresolved_raw_names: set[str] = set()
    if raw_names:
        lowered = {n.lower(): n for n in raw_names}
        resolved_alias_rows = await db.execute(
            select(ArtistAlias.alias_text, CanonicalArtist)
            .join(CanonicalArtist, ArtistAlias.canonical_artist_id == CanonicalArtist.id)
            .where(func.lower(ArtistAlias.alias_text).in_(lowered.keys()))
        )
        resolved_lower_keys: set[str] = set()
        for alias_text, c in resolved_alias_rows.all():
            canonicals.setdefault(c.id, c)
            resolved_lower_keys.add(alias_text.lower())

        # 별칭 row 없이 canonical_name 자체와 원문이 정확히 일치하는 경우도 커버
        name_match_result = await db.execute(
            select(CanonicalArtist).where(func.lower(CanonicalArtist.canonical_name).in_(lowered.keys()))
        )
        for c in name_match_result.scalars().all():
            canonicals.setdefault(c.id, c)
            resolved_lower_keys.add(c.canonical_name.lower())

        unresolved_raw_names = {lowered[key] for key in lowered.keys() - resolved_lower_keys}

    if not canonicals and not unresolved_raw_names:
        return []

    membership_rows = await db.execute(
        select(ArtistGroupMembership).where(
            ArtistGroupMembership.member_canonical_id.in_(canonicals.keys()),
            ArtistGroupMembership.is_current.is_(True),
        )
    )
    groups_by_member: dict = {}
    group_ids_needed: set = set()
    for m in membership_rows.scalars().all():
        groups_by_member.setdefault(m.member_canonical_id, []).append(m.group_canonical_id)
        if m.group_canonical_id not in canonicals:
            group_ids_needed.add(m.group_canonical_id)

    if group_ids_needed:
        group_result = await db.execute(select(CanonicalArtist).where(CanonicalArtist.id.in_(group_ids_needed)))
        for c in group_result.scalars().all():
            canonicals[c.id] = c

    # 멤버-그룹 판정 + "실제 공연이 있는지" 판정을 위해 canonical들의 별칭까지 모아서, "자기
    # 이름(canonical_name/별칭 어느 쪽이든)으로 등록된 공연이 실제로 있는지" 한 번에 확인.
    # 그룹 확장(바로 위) 이후에 계산해야 새로 추가된 그룹의 공연 여부까지 같이 잡힘
    alias_rows = await db.execute(
        select(ArtistAlias.canonical_artist_id, ArtistAlias.alias_text).where(
            ArtistAlias.canonical_artist_id.in_(canonicals.keys())
        )
    )
    names_by_canonical: dict = {cid: {canonicals[cid].canonical_name} for cid in canonicals}
    for cid, alias_text in alias_rows.all():
        names_by_canonical.setdefault(cid, set()).add(alias_text)

    all_names_lower = {n.lower() for names in names_by_canonical.values() for n in names}
    own_concert_result = await db.execute(
        select(name_unnested.c.name.distinct()).where(func.lower(name_unnested.c.name).in_(all_names_lower))
    )
    has_concert_names = {n.lower() for n in own_concert_result.scalars().all() if n}
    has_own_concert = {
        cid: any(n.lower() in has_concert_names for n in names) for cid, names in names_by_canonical.items()
    }

    # 멤버가 자기 이름 공연이 없으면(밴드 라인업에만 존재) 팔로우해도 소식이 절대 안 떠서
    # (_create_news_feeds_for_concert가 정확한 문자열 일치만 봄) 멤버는 빼고 그룹만 노출,
    # 있으면 멤버+그룹 둘 다. 그룹→멤버 전원 노출은 결과가 난잡해져서 안 함.
    # + 그룹/멤버관계 없는 단독 아티스트든 그룹이든, 실제 공연이 하나도 없으면(has_own_concert
    # False) 검색 결과에서 아예 뺌 - 밴드-멤버 관계 전개로 팔로우 매칭용으로만 미리 채워둔
    # 아티스트가 3천여 개나 있어(2026-09-11 실측) 전부 검색에 걸리면 결과가 지저분해짐
    final_ids: set = set()
    for cid in canonicals:
        group_ids = groups_by_member.get(cid)
        if group_ids is None:
            if has_own_concert.get(cid):
                final_ids.add(cid)  # 그룹이거나 멤버 관계가 없는 아티스트 - 공연 있으면 노출
            continue
        if has_own_concert.get(cid):
            final_ids.add(cid)  # 자기 공연 있는 멤버는 자신도 노출
        final_ids.update(gid for gid in group_ids if has_own_concert.get(gid))  # 그룹도 공연 있을 때만

    entries = [
        {"name": _display_value(canonicals[cid]), "profile_image_url": canonicals[cid].profile_image_url}
        for cid in final_ids
    ]
    entries += [{"name": n, "profile_image_url": None} for n in unresolved_raw_names]

    # 질의어를 포함하는 이름을 앞으로, 그 안에서는 이름이 짧은 순
    # (기존 프론트 artist_search_service.dart의 정렬 기준과 동일)
    q_lower = q.lower()
    ranked = sorted(entries, key=lambda e: (0 if q_lower in e["name"].lower() else 1, len(e["name"])))

    # canonical_name과 원문 표기가 우연히 같은 경우 등으로 이름이 중복될 수 있어 순서 유지하며 제거
    seen: set[str] = set()
    deduped = []
    for entry in ranked:
        key = entry["name"].lower()
        if key in seen:
            continue
        seen.add(key)
        deduped.append(entry)

    return deduped[:limit]
