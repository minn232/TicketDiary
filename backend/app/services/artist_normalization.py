import logging
from datetime import datetime, timezone

import httpx
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import AsyncSessionLocal
from app.models.artist_normalization import (
    ArtistAlias,
    ArtistGroupMembership,
    ArtistNormalizationStatus,
    CanonicalArtist,
)
from app.models.concert import Concert
from app.models.lineup import ConcertLineup
from app.services.musicbrainz import ArtistCandidate, fetch_member_of_band_relations, search_artist

logger = logging.getLogger(__name__)

# 1등 후보라도 이 점수 미만이면 확정하지 않음(_FUZZY_MATCH_THRESHOLD와 같은 취지)
_MIN_MATCH_SCORE = 90

# 후보가 2명 이상일 때, 1등과 2등의 점수 차이가 이 이상이면 "1등이 확실히 두드러진다"고 보고
# 확정. HAKIM 실측 사례(1등100/2등98, 차이 2)는 걸러지고, 차이가 크게 나는 경우만 통과시키려는
# 의도라 넉넉하게 잡음 - 임계치를 낮추면 HAKIM류가 다시 통과할 위험이 커짐
_MIN_SCORE_GAP = 15

# 1회 배치 실행당 처리 상한 (안전장치 - 콘서트 신규 유입 급증 시 하룻밤에 다 못 끝내도 다음날 이어감)
_DEFAULT_BATCH_LIMIT = 500


def _normalize_alias_text(text: str) -> str:
    return text.strip().lower()


# 로컬 alias 테이블에서 이미 확인된 canonical을 찾는다 - 있으면 API 호출 없이 즉시 재사용.
# canonical_name 자체와도 비교(정확히 canonical 표기 그대로 다시 들어온 경우, 별도 alias row 없이도 바로 인식)
async def find_canonical_by_alias(db: AsyncSession, name: str) -> CanonicalArtist | None:
    normalized = _normalize_alias_text(name)
    result = await db.execute(
        select(CanonicalArtist)
        .join(ArtistAlias, ArtistAlias.canonical_artist_id == CanonicalArtist.id)
        .where(func.lower(ArtistAlias.alias_text) == normalized)
        .limit(1)
    )
    found = result.scalar_one_or_none()
    if found is not None:
        return found

    result = await db.execute(
        select(CanonicalArtist).where(func.lower(CanonicalArtist.canonical_name) == normalized).limit(1)
    )
    return result.scalar_one_or_none()


async def _register_alias_if_new(db: AsyncSession, canonical: CanonicalArtist, alias_text: str, source: str) -> None:
    normalized = _normalize_alias_text(alias_text)
    existing = await db.execute(
        select(ArtistAlias.id).where(
            ArtistAlias.canonical_artist_id == canonical.id,
            func.lower(ArtistAlias.alias_text) == normalized,
        )
    )
    if existing.scalar_one_or_none() is not None:
        return
    db.add(ArtistAlias(canonical_artist_id=canonical.id, alias_text=alias_text, source=source))


# created=True를 반환하면 호출부가 "이 canonical은 이번에 처음 만들어졌다"고 판단해서 관계
# 조회(_fetch_and_store_group_relations)를 딱 한 번만 트리거하는 데 씀 - 이미 있던 canonical은
# 예전에 만들어졌을 때 이미 관계 조회를 거쳤을 것이므로 다시 조회하지 않음
async def _get_or_create_canonical_by_mbid(
    db: AsyncSession, mbid: str, canonical_name: str
) -> tuple[CanonicalArtist, bool]:
    result = await db.execute(select(CanonicalArtist).where(CanonicalArtist.mbid == mbid))
    existing = result.scalar_one_or_none()
    if existing is not None:
        return existing, False
    canonical = CanonicalArtist(mbid=mbid, canonical_name=canonical_name)
    db.add(canonical)
    await db.flush()  # id 확보(뒤이어 ArtistAlias/ArtistGroupMembership이 FK로 참조)
    return canonical, True


async def _register_membership_if_new(db: AsyncSession, member_id, group_id) -> None:
    existing = await db.execute(
        select(ArtistGroupMembership.id).where(
            ArtistGroupMembership.member_canonical_id == member_id,
            ArtistGroupMembership.group_canonical_id == group_id,
        )
    )
    if existing.scalar_one_or_none() is not None:
        return
    db.add(ArtistGroupMembership(member_canonical_id=member_id, group_canonical_id=group_id, source="musicbrainz"))


# 새로 매치된 canonical 1건의 "member of band" 관계를 딱 1단계만 조회해서 저장 - 상대방도
# canonical로 등록하되 상대방의 관계까지 연쇄 조회하지는 않음(API 호출량 방지). 조회 자체가
# 실패해도(네트워크 오류 등) 예외를 삼키고 넘어간다 - 본체 매치는 이미 확정됐고 관계는 보강 데이터일 뿐
async def _fetch_and_store_group_relations(
    db: AsyncSession, canonical: CanonicalArtist, client: httpx.AsyncClient
) -> None:
    try:
        relations = await fetch_member_of_band_relations(canonical.mbid, client=client)
    except Exception as e:
        logger.warning(f"MusicBrainz 관계 조회 실패, 건너뜀 (mbid={canonical.mbid}): {e}")
        return

    for rel in relations:
        if not rel.is_current:
            continue  # 탈퇴 멤버는 저장만 하지 않고 통째로 건너뜀(정책: 현역 멤버만 매칭에 사용)
        related, _ = await _get_or_create_canonical_by_mbid(db, rel.mbid, rel.name)
        if rel.type == "Group":
            await _register_membership_if_new(db, canonical.id, related.id)
        else:
            await _register_membership_if_new(db, related.id, canonical.id)


# kopis.py의 팔로우 인덱스를 밴드<->현재 멤버 관계로 한 단계 더 넓힌다 - "잔나비"를 팔로우한
# 유저가 KOPIS 멤버명만 있는 콘서트도 받고, 반대로 멤버명을 팔로우한 유저가 밴드명만 있는
# 콘서트도 받게 됨(대칭 처리). DB 로컬 조회만 하며 관계/alias 데이터가 없으면 조용히 리턴
async def expand_follow_index_with_group_relations(db: AsyncSession, index: dict[str, list[tuple]]) -> None:
    keys = list(index.keys())
    if not keys:
        return

    canonical_ids_by_key: dict[str, set] = {}
    alias_rows = await db.execute(
        select(ArtistAlias.alias_text, ArtistAlias.canonical_artist_id).where(
            func.lower(ArtistAlias.alias_text).in_(keys)
        )
    )
    for alias_text, cid in alias_rows.all():
        canonical_ids_by_key.setdefault(alias_text.lower(), set()).add(cid)

    # alias row 없이 canonical_name 자체로 팔로우한 경우도 커버
    canonical_rows = await db.execute(
        select(CanonicalArtist.canonical_name, CanonicalArtist.id).where(
            func.lower(CanonicalArtist.canonical_name).in_(keys)
        )
    )
    for name, cid in canonical_rows.all():
        canonical_ids_by_key.setdefault(name.lower(), set()).add(cid)

    all_ids = {cid for ids in canonical_ids_by_key.values() for cid in ids}
    if not all_ids:
        return

    membership_rows = await db.execute(
        select(ArtistGroupMembership).where(
            ArtistGroupMembership.is_current.is_(True),
            (ArtistGroupMembership.member_canonical_id.in_(all_ids))
            | (ArtistGroupMembership.group_canonical_id.in_(all_ids)),
        )
    )
    memberships = membership_rows.scalars().all()
    if not memberships:
        return

    related_ids: set = set()
    for m in memberships:
        if m.member_canonical_id in all_ids:
            related_ids.add(m.group_canonical_id)
        if m.group_canonical_id in all_ids:
            related_ids.add(m.member_canonical_id)
    if not related_ids:
        return

    names_by_related_id: dict = {}
    related_alias_rows = await db.execute(
        select(ArtistAlias.canonical_artist_id, ArtistAlias.alias_text).where(
            ArtistAlias.canonical_artist_id.in_(related_ids)
        )
    )
    for cid, alias_text in related_alias_rows.all():
        names_by_related_id.setdefault(cid, set()).add(alias_text)
    related_canonical_rows = await db.execute(
        select(CanonicalArtist.id, CanonicalArtist.canonical_name).where(CanonicalArtist.id.in_(related_ids))
    )
    for cid, name in related_canonical_rows.all():
        names_by_related_id.setdefault(cid, set()).add(name)

    for key, cids in canonical_ids_by_key.items():
        followers = index.get(key)
        if not followers:
            continue
        for cid in cids:
            for m in memberships:
                if m.member_canonical_id == cid:
                    related_id = m.group_canonical_id
                elif m.group_canonical_id == cid:
                    related_id = m.member_canonical_id
                else:
                    continue
                for related_name in names_by_related_id.get(related_id, ()):
                    index.setdefault(related_name.lower(), []).extend(followers)


# 새로 병합된(또는 이미 저장돼 있는) 원본 표기들을 정규화 대기열에 pending으로 적립.
# 외부 호출 없음, 이미 큐잉된 표기(unique constraint)는 조용히 스킵 - 웹훅에서 매번 호출해도 안전.
async def queue_for_normalization(
    db: AsyncSession, concert_id, names: list[str], *, commit: bool = True
) -> None:
    names = [n for n in {n.strip() for n in names} if n]
    if not names:
        return

    existing = await db.execute(
        select(ArtistNormalizationStatus.artist_text).where(
            ArtistNormalizationStatus.concert_id == concert_id,
            ArtistNormalizationStatus.artist_text.in_(names),
        )
    )
    already_queued = set(existing.scalars().all())

    added = False
    for name in names:
        if name in already_queued:
            continue
        db.add(ArtistNormalizationStatus(concert_id=concert_id, artist_text=name, status="pending"))
        added = True

    if added and commit:
        await db.commit()


# LLM이 포스터에서 일부 멤버만 추출하는 경우가 흔해서(예: 5인조 중 1~2명) 관계 그래프가
# 엉성해진다 - KOPIS API를 다시 조회해 원본 라인업 전체를 큐에 추가(concert.artist_name은 안
# 건드림). pending row가 있는 콘서트만 대상이라 이미 다 처리된 콘서트는 빠짐(알려진 한계)
async def _supplement_from_kopis_originals(db: AsyncSession, kopis_client, concert_ids: list) -> None:
    if not concert_ids:
        return

    # 순환 임포트 방지: kopis.py가 이미 이 모듈(expand_follow_index_with_group_relations)을
    # 가져다 쓰고 있어서, 모듈 최상단에서 반대 방향으로 가져오면 순환 임포트가 됨
    from app.services.kopis import _fetch_kopis_detail_data

    result = await db.execute(
        select(Concert.id, Concert.kopis_id).where(
            Concert.id.in_(concert_ids), Concert.kopis_id.isnot(None)
        )
    )
    for concert_id, kopis_id in result.all():
        try:
            data = await _fetch_kopis_detail_data(kopis_client, kopis_id)
        except Exception as e:
            logger.warning(f"KOPIS 원본 라인업 보강 조회 실패, 건너뜀 (kopis_id={kopis_id}): {e}")
            continue
        kopis_names = data.get("artist_name") or []
        if kopis_names:
            await queue_for_normalization(db, concert_id, kopis_names, commit=False)


# 후보가 1명뿐이거나(동명이인 없음), 1등과 2등 점수 차이가 크면(1등이 확실히 두드러짐) 자동 확정.
# 국적(country:KR)이 아니라 "후보 유일성"이 기준 - 흔한 이름은 후보가 여럿 몰려있어(HAKIM 사례)
# 걸러지고, 내한 아티스트처럼 애초에 country가 없는 경우도 후보가 하나면 정상 확정된다
def decide_match(candidates: list[ArtistCandidate]) -> tuple[str, ArtistCandidate | None]:
    if not candidates:
        return "unconfirmed", None

    top = candidates[0]
    if top.score < _MIN_MATCH_SCORE:
        return "unconfirmed", None
    if len(candidates) == 1:
        return "matched", top

    second = candidates[1]
    if top.score - second.score >= _MIN_SCORE_GAP:
        return "matched", top
    return "ambiguous", None


# concert.artist_name 배열 + 같은 표기를 쓰는 concert_lineups row들의 표기를 canonical로
# 치환한다. concert_lineups는 (concert_id, artist, performance_date) unique 제약이 있어서,
# 치환 대상 자리에 canonical 표기가 이미 있으면 원본 row는 지우고(중복 방지), 없으면 이름만 바꾼다.
async def apply_canonical_replacement(
    db: AsyncSession, concert_id, raw_text: str, canonical_name: str
) -> None:
    if raw_text == canonical_name:
        return

    concert = await db.get(Concert, concert_id)
    if concert is None:
        return

    if concert.artist_name and raw_text in concert.artist_name:
        concert.artist_name = sorted(
            {canonical_name if n == raw_text else n for n in concert.artist_name}
        )

    result = await db.execute(
        select(ConcertLineup).where(
            ConcertLineup.concert_id == concert_id, ConcertLineup.artist == raw_text
        )
    )
    raw_rows = result.scalars().all()
    if not raw_rows:
        return

    existing_result = await db.execute(
        select(ConcertLineup).where(
            ConcertLineup.concert_id == concert_id, ConcertLineup.artist == canonical_name
        )
    )
    existing_by_date = {row.performance_date: row for row in existing_result.scalars().all()}

    for row in raw_rows:
        target = existing_by_date.get(row.performance_date)
        if target is None:
            row.artist = canonical_name
            existing_by_date[row.performance_date] = row
        else:
            # 이미 canonical 표기의 row가 그 날짜에 있음 - 더 신뢰도 높은 source만 승격시키고
            # 원본(raw_text) row는 중복이라 삭제 (lineup.py의 _SOURCE_PRIORITY와 동일한 취지)
            if row.source == "crawl" and target.source != "crawl":
                target.source = "crawl"
            await db.delete(row)


async def _process_one(
    db: AsyncSession, client: httpx.AsyncClient, row: ArtistNormalizationStatus
) -> str:
    canonical = await find_canonical_by_alias(db, row.artist_text)
    if canonical is not None:
        await apply_canonical_replacement(db, row.concert_id, row.artist_text, canonical.canonical_name)
        row.status = "matched"
        return "matched"

    candidates = await search_artist(row.artist_text, client=client)
    row.attempt_count += 1
    row.last_attempted_at = datetime.now(timezone.utc)

    status, winner = decide_match(candidates)
    row.status = status

    if status == "matched" and winner is not None:
        canonical, created = await _get_or_create_canonical_by_mbid(db, winner.mbid, winner.name)
        await _register_alias_if_new(db, canonical, row.artist_text, source="musicbrainz")
        if created:
            await _fetch_and_store_group_relations(db, canonical, client)
        await apply_canonical_replacement(db, row.concert_id, row.artist_text, canonical.canonical_name)

    return status


# 정규화 대기열(pending)을 소비하는 배치 본체. 실패(네트워크 오류 등)는 status를 안 바꾸고
# pending으로 남겨둬서 다음 실행이 자동으로 재시도하게 함 - 확정 응답을 받은 것만 상태를 바꿈.
async def normalize_pending_artists(limit: int = _DEFAULT_BATCH_LIMIT, *, dry_run: bool = False) -> dict[str, int]:
    stats = {"processed": 0, "matched": 0, "unconfirmed": 0, "ambiguous": 0, "error": 0}

    async with AsyncSessionLocal() as db:
        pending_concert_ids = (
            await db.execute(select(ArtistNormalizationStatus.concert_id).distinct().where(
                ArtistNormalizationStatus.status == "pending"
            ))
        ).scalars().all()
        if pending_concert_ids:
            async with httpx.AsyncClient(timeout=10.0) as kopis_client:
                await _supplement_from_kopis_originals(db, kopis_client, pending_concert_ids)

        result = await db.execute(
            select(ArtistNormalizationStatus)
            .where(ArtistNormalizationStatus.status == "pending")
            .order_by(ArtistNormalizationStatus.created_at)
            .limit(limit)
        )
        rows = result.scalars().all()
        if not rows:
            return stats

        logger.info(f"MusicBrainz 정규화 대상 {len(rows)}건")
        async with httpx.AsyncClient(timeout=10.0) as client:
            for row in rows:
                try:
                    status = await _process_one(db, client, row)
                    stats[status] = stats.get(status, 0) + 1
                except Exception as e:
                    logger.warning(f"아티스트 정규화 실패, pending 유지 (artist_text={row.artist_text!r}): {e}")
                    stats["error"] += 1
                    continue
                stats["processed"] += 1

        if dry_run:
            await db.rollback()
            logger.info(f"[dry-run] 커밋하지 않고 롤백함: {stats}")
        else:
            await db.commit()
            logger.info(f"MusicBrainz 정규화 완료: {stats}")

    return stats
