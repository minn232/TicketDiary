import logging
from datetime import datetime, timezone

import httpx
from fastapi import HTTPException
from sqlalchemy import and_, func, or_, select
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
from app.services.artist_blocklist import is_blocklisted_artist_name
from app.services.artist_matching import _compact, _contains_hangul, normalize_artist_names
from app.services.musicbrainz import (
    ArtistCandidate,
    fetch_member_of_band_relations,
    fetch_spotify_artist_url,
    fetch_wikidata_qid,
    search_artist,
)
from app.services.spotify import fetch_oembed_thumbnail
from app.services.wikidata import fetch_artist_image_url, fetch_korean_label

logger = logging.getLogger(__name__)

# 1등 후보라도 이 점수 미만이면 확정하지 않음(_FUZZY_MATCH_THRESHOLD와 같은 취지)
_MIN_MATCH_SCORE = 90

# 후보가 2명 이상일 때, 1등과 2등의 점수 차이가 이 이상이면 "1등이 확실히 두드러진다"고 보고
# 확정. HAKIM 실측 사례(1등100/2등98, 차이 2)는 걸러지고, 차이가 크게 나는 경우만 통과시키려는
# 의도라 넉넉하게 잡음 - 임계치를 낮추면 HAKIM류가 다시 통과할 위험이 커짐
_MIN_SCORE_GAP = 15

# 부분 문자열 관계인 두 이름의 길이 비율이 이 미만이면 의심스러운 조각 매치로 봄
# (실측: 최정철->정철 2/3=0.67, METHOD->The Crystal Method 6/16=0.375 - 전부 잡힘)
_FRAGMENT_LENGTH_RATIO_MIN = 0.7

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


async def _register_membership_if_new(
    db: AsyncSession, member_id, group_id, source: str = "musicbrainz"
) -> None:
    existing = await db.execute(
        select(ArtistGroupMembership.id).where(
            ArtistGroupMembership.member_canonical_id == member_id,
            ArtistGroupMembership.group_canonical_id == group_id,
        )
    )
    if existing.scalar_one_or_none() is not None:
        return
    db.add(ArtistGroupMembership(member_canonical_id=member_id, group_canonical_id=group_id, source=source))


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
        related, related_created = await _get_or_create_canonical_by_mbid(db, rel.mbid, rel.name)
        if rel.type == "Group":
            await _register_membership_if_new(db, canonical.id, related.id)
            if related_created:
                # 멤버 쪽에서 발견한 그룹은 아직 그 그룹의 "전체" 로스터를 모름(이 관계 1건만
                # 앎) - 그룹 표기 통합(멤버 전원 있으면 그룹명으로) 판단에 전체 로스터가 필요해서
                # 그룹당 1회만 추가로 조회. created 플래그로 막아서 무한 연쇄는 안 됨
                await _fetch_and_store_group_relations(db, related, client)
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


# 같은 스크립트(둘 다 한글 포함 또는 둘 다 미포함)에서 한쪽이 다른 쪽의 부분 문자열인데 길이
# 차이가 크면 의심스러운 매치로 본다(성이 빠지거나 장르/일반명사가 유명 아티스트에 우연히 걸리는
# 패턴). 스크립트가 다르면 정상 별칭 매치(권지용->G-DRAGON 등)일 수 있어 검사하지 않는다
def _is_suspicious_fragment_match(query: str, candidate_name: str) -> bool:
    if _contains_hangul(query) != _contains_hangul(candidate_name):
        return False
    q, c = _compact(query), _compact(candidate_name)
    if not q or not c or q == c or not (q in c or c in q):
        return False
    shorter_len, longer_len = sorted([len(q), len(c)])
    return shorter_len / longer_len < _FRAGMENT_LENGTH_RATIO_MIN


# 후보가 1명뿐이거나 1등-2등 점수차가 크면(HAKIM 사례처럼 몰려있지 않으면) 자동 확정 - 국적이
# 아니라 "후보 유일성"이 기준. 다만 확정 직전에 쿼리명-후보명이 부분 문자열 관계
# (_is_suspicious_fragment_match)면 한 번 더 걸러 ambiguous로 내림("정철"=최정철의 부분 등)
def decide_match(candidates: list[ArtistCandidate], query_name: str) -> tuple[str, ArtistCandidate | None]:
    if not candidates:
        return "unconfirmed", None

    top = candidates[0]
    if top.score < _MIN_MATCH_SCORE:
        return "unconfirmed", None

    if len(candidates) == 1:
        matched = True
    else:
        second = candidates[1]
        matched = top.score - second.score >= _MIN_SCORE_GAP

    if not matched:
        return "ambiguous", None
    if _is_suspicious_fragment_match(query_name, top.name):
        return "ambiguous", None
    return "matched", top


# canonical의 화면 표시용 문자열 - display_name이 있으면 그걸(Wikidata 한글 label 자동 채택
# 또는 admin 수동 선택), 없으면 canonical_name(MusicBrainz 원문) 그대로
def _display_value(canonical: CanonicalArtist) -> str:
    return canonical.display_name or canonical.canonical_name


# concert.artist_name 배열 + 같은 표기를 쓰는 concert_lineups row들의 표기를 display_value로
# 치환한다(매칭 키인 canonical_name이 아니라 실제 화면에 보일 문자열). concert_lineups는
# (concert_id, artist, performance_date) unique 제약이 있어서, 치환 대상 자리에 display_value가
# 이미 있으면 원본 row는 지우고(중복 방지), 없으면 이름만 바꾼다.
async def apply_canonical_replacement(
    db: AsyncSession, concert_id, raw_text: str, display_value: str, *, clear_admin_review: bool = False
) -> None:
    if raw_text == display_value:
        return

    concert = await db.get(Concert, concert_id)
    if concert is None:
        return

    if concert.artist_name and raw_text in concert.artist_name:
        concert.artist_name = sorted(
            {display_value if n == raw_text else n for n in concert.artist_name}
        )
        # clear_admin_review=True는 자동 배치 호출부(정규화/그룹명 정리)에서만 씀 - 관리자가
        # 직접 이 콘서트를 고친 경우(confirm_artist_name_change 등)는 검수한 것이므로 그대로 둠
        if clear_admin_review:
            concert.admin_reviewed_at = None

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
            ConcertLineup.concert_id == concert_id, ConcertLineup.artist == display_value
        )
    )
    existing_by_date = {row.performance_date: row for row in existing_result.scalars().all()}

    for row in raw_rows:
        target = existing_by_date.get(row.performance_date)
        if target is None:
            row.artist = display_value
            existing_by_date[row.performance_date] = row
        else:
            # 이미 display_value 표기의 row가 그 날짜에 있음 - 더 신뢰도 높은 source만 승격시키고
            # 원본(raw_text) row는 중복이라 삭제 (lineup.py의 _SOURCE_PRIORITY와 동일한 취지)
            if row.source == "crawl" and target.source != "crawl":
                target.source = "crawl"
            await db.delete(row)


# 유저 확정(G안) API/관리자 페이지가 공유하는 핵심 로직 - original_name을 confirmed_name으로
# 바꾸고 alias/canonical을 등록한다. 서비스 레이어에서 바로 HTTPException을 던짐(raw int,
# 프로젝트 컨벤션) - 호출부(엔드포인트)는 그대로 전파만 하면 됨
async def confirm_artist_name_change(
    db: AsyncSession, concert_id, original_name: str, confirmed_name: str
) -> Concert:
    concert = await db.get(Concert, concert_id)
    if concert is None:
        raise HTTPException(status_code=404, detail="공연 정보를 찾을 수 없습니다.")

    original_name = original_name.strip()
    confirmed_name = confirmed_name.strip()
    if not original_name or not confirmed_name:
        raise HTTPException(status_code=400, detail="아티스트명이 비어있습니다.")
    if original_name not in (concert.artist_name or []):
        raise HTTPException(status_code=400, detail="해당 아티스트가 이 공연에 없습니다.")
    if is_blocklisted_artist_name(confirmed_name):
        raise HTTPException(status_code=400, detail="아티스트명으로 쓸 수 없는 값입니다.")

    # 기존 canonical 표기들과 퍼지/로마자 매칭해서 근접 중복(오타, 대소문자 등)이면 새로
    # 만들지 않고 기존 것을 재사용 - concert.artist_name 병합 때 쓰는 것과 동일한 로직/임계치
    existing_canonicals = (await db.execute(select(CanonicalArtist))).scalars().all()
    canonical_names = {c.canonical_name for c in existing_canonicals}
    resolved_name = normalize_artist_names([confirmed_name], canonical_names)[0]

    canonical = next((c for c in existing_canonicals if c.canonical_name == resolved_name), None)
    if canonical is None:
        canonical = CanonicalArtist(mbid=None, canonical_name=resolved_name)
        db.add(canonical)
        await db.flush()

    for alias_text in {original_name, confirmed_name}:
        await _register_alias_if_new(db, canonical, alias_text, source="user_input")

    await apply_canonical_replacement(db, concert_id, original_name, resolved_name)

    status_result = await db.execute(
        select(ArtistNormalizationStatus).where(
            ArtistNormalizationStatus.concert_id == concert_id,
            ArtistNormalizationStatus.artist_text == original_name,
        )
    )
    status_row = status_result.scalar_one_or_none()
    if status_row is not None:
        status_row.status = "matched"

    await db.commit()
    await db.refresh(concert)
    return concert


# status="suggested" 행을 admin이 승인/거부 - 승인이면 그제서야 실제로 병합 적용(alias는 이미
# 등록돼 있으므로 새로 안 만듦), 거부면 이 공연에선 별개 인물로 보고 unconfirmed로 되돌림(같은
# 문자열이 다른 공연에서 다시 나오면 그때 또 물어봄 - 전역으로 차단하지 않음)
async def resolve_artist_suggestion(db: AsyncSession, concert_id, artist_text: str, accept: bool) -> Concert:
    concert = await db.get(Concert, concert_id)
    if concert is None:
        raise HTTPException(status_code=404, detail="공연 정보를 찾을 수 없습니다.")

    artist_text = artist_text.strip()
    status_result = await db.execute(
        select(ArtistNormalizationStatus).where(
            ArtistNormalizationStatus.concert_id == concert_id,
            ArtistNormalizationStatus.artist_text == artist_text,
        )
    )
    row = status_result.scalar_one_or_none()
    if row is None or row.status != "suggested" or row.suggested_canonical_id is None:
        raise HTTPException(status_code=400, detail="대기 중인 병합 제안이 없습니다.")

    if accept:
        canonical = await db.get(CanonicalArtist, row.suggested_canonical_id)
        await apply_canonical_replacement(
            db, concert_id, artist_text, _display_value(canonical), clear_admin_review=True
        )
        row.status = "matched"
    else:
        row.status = "unconfirmed"
    row.suggested_canonical_id = None

    await db.commit()
    await db.refresh(concert)
    return concert


# 아티스트가 아닌데 잘못 들어간 표기를 통째로 제거(수정이 아니라 삭제) - 관리자 페이지 전용.
# concert.artist_name에서 빼고, 정규화 큐/라인업에 같은 표기가 남아있으면 같이 정리해서
# 다음 배치가 다시 큐잉하지 않게 한다
async def remove_artist_name(db: AsyncSession, concert_id, name: str) -> Concert:
    concert = await db.get(Concert, concert_id)
    if concert is None:
        raise HTTPException(status_code=404, detail="공연 정보를 찾을 수 없습니다.")

    name = name.strip()
    if not name or name not in (concert.artist_name or []):
        raise HTTPException(status_code=400, detail="해당 아티스트가 이 공연에 없습니다.")

    concert.artist_name = sorted(n for n in concert.artist_name if n != name)

    status_result = await db.execute(
        select(ArtistNormalizationStatus).where(
            ArtistNormalizationStatus.concert_id == concert_id,
            ArtistNormalizationStatus.artist_text == name,
        )
    )
    for row in status_result.scalars().all():
        await db.delete(row)

    lineup_result = await db.execute(
        select(ConcertLineup).where(ConcertLineup.concert_id == concert_id, ConcertLineup.artist == name)
    )
    for row in lineup_result.scalars().all():
        await db.delete(row)

    await db.commit()
    await db.refresh(concert)
    return concert


# LLM/KOPIS 둘 다 놓친 아티스트를 관리자가 직접 추가 - confirm_artist_name_change처럼 기존
# canonical과 퍼지매칭해 재사용하되 MusicBrainz 조회 없이 즉시 반영(추가를 안 늦춤). canonical도
# 반환해서 호출부가 mbid 없으면 try_link_canonical_to_musicbrainz를 백그라운드로 걸 수 있게 함
async def add_artist_name(db: AsyncSession, concert_id, name: str) -> tuple[Concert, CanonicalArtist]:
    concert = await db.get(Concert, concert_id)
    if concert is None:
        raise HTTPException(status_code=404, detail="공연 정보를 찾을 수 없습니다.")

    name = name.strip()
    if not name:
        raise HTTPException(status_code=400, detail="아티스트명이 비어있습니다.")
    if is_blocklisted_artist_name(name):
        raise HTTPException(status_code=400, detail="아티스트명으로 쓸 수 없는 값입니다.")

    existing_canonicals = (await db.execute(select(CanonicalArtist))).scalars().all()
    canonical_names = {c.canonical_name for c in existing_canonicals}
    resolved_name = normalize_artist_names([name], canonical_names)[0]

    if resolved_name in (concert.artist_name or []):
        raise HTTPException(status_code=400, detail="이미 등록된 아티스트입니다.")

    canonical = next((c for c in existing_canonicals if c.canonical_name == resolved_name), None)
    if canonical is None:
        canonical = CanonicalArtist(mbid=None, canonical_name=resolved_name)
        db.add(canonical)
        await db.flush()
    await _register_alias_if_new(db, canonical, name, source="user_input")

    concert.artist_name = sorted(set(concert.artist_name or []) | {resolved_name})

    await db.commit()
    await db.refresh(concert)
    return concert, canonical


# 관리자 페이지 전용: "밴드명 + 멤버 여러 명"이 개별 표기로 따로 뽑힌 공연을 밴드명 하나로
# 접고, 멤버는 ArtistGroupMembership으로 등록(source="admin")한다. 자동 정리
# (_collapse_members_to_group_names)는 이 관계가 MusicBrainz에 없으면 못 뭉치는데, 여기서
# 등록한 관계는 전역이라 이후 같은 밴드가 나오는 다른 콘서트에도 자동 적용됨
async def set_group_membership(
    db: AsyncSession, concert_id, group_name: str, member_names: list[str]
) -> Concert:
    concert = await db.get(Concert, concert_id)
    if concert is None:
        raise HTTPException(status_code=404, detail="공연 정보를 찾을 수 없습니다.")

    group_name = group_name.strip()
    member_names = sorted({n.strip() for n in member_names if n.strip()})
    if not group_name or not member_names:
        raise HTTPException(status_code=400, detail="밴드명과 멤버명을 모두 입력해야 합니다.")
    if group_name in member_names:
        raise HTTPException(status_code=400, detail="밴드명이 멤버 목록에도 있습니다.")
    missing = [n for n in member_names if n not in (concert.artist_name or [])]
    if missing:
        raise HTTPException(status_code=400, detail=f"이 공연에 없는 이름입니다: {', '.join(missing)}")

    existing_canonicals = (await db.execute(select(CanonicalArtist))).scalars().all()
    canonical_names = {c.canonical_name for c in existing_canonicals}

    # add_artist_name/confirm_artist_name_change와 동일한 퍼지매칭 재사용 후 없으면 새로 생성
    async def _resolve(name: str) -> CanonicalArtist:
        resolved = normalize_artist_names([name], canonical_names)[0]
        canonical = next((c for c in existing_canonicals if c.canonical_name == resolved), None)
        if canonical is None:
            canonical = CanonicalArtist(mbid=None, canonical_name=resolved)
            db.add(canonical)
            await db.flush()
            existing_canonicals.append(canonical)
            canonical_names.add(resolved)
        await _register_alias_if_new(db, canonical, name, source="admin")
        return canonical

    group_canonical = await _resolve(group_name)
    for member_name in member_names:
        member_canonical = await _resolve(member_name)
        await _register_membership_if_new(db, member_canonical.id, group_canonical.id, source="admin")

    concert.artist_name = sorted((set(concert.artist_name or []) - set(member_names)) | {group_canonical.canonical_name})

    # remove_artist_name과 동일하게, 접혀 없어진 멤버 표기의 정규화 큐/라인업 row 정리
    status_result = await db.execute(
        select(ArtistNormalizationStatus).where(
            ArtistNormalizationStatus.concert_id == concert_id,
            ArtistNormalizationStatus.artist_text.in_(member_names),
        )
    )
    for row in status_result.scalars().all():
        await db.delete(row)

    lineup_result = await db.execute(
        select(ConcertLineup).where(
            ConcertLineup.concert_id == concert_id, ConcertLineup.artist.in_(member_names)
        )
    )
    for row in lineup_result.scalars().all():
        await db.delete(row)

    # 밴드명 표기의 정규화 큐 상태는 확정으로 처리
    group_status_result = await db.execute(
        select(ArtistNormalizationStatus).where(
            ArtistNormalizationStatus.concert_id == concert_id,
            ArtistNormalizationStatus.artist_text == group_name,
        )
    )
    for row in group_status_result.scalars().all():
        row.status = "matched"

    await db.commit()
    await db.refresh(concert)
    return concert


# add_artist_name이 건너뛴 MusicBrainz 조회를 응답 이후 백그라운드에서 한 번 시도 - 매치되면
# mbid/관계/Wikidata 한글 별칭까지 채워지고(그룹이면 로스터까지 확보), 실패해도 무해하게
# mbid=None 그대로 남음. canonical_name은 admin이 정한 표기를 그대로 유지(조회 결과로 덮어쓰지 않음)
async def try_link_canonical_to_musicbrainz(canonical_id) -> None:
    async with AsyncSessionLocal() as db:
        canonical = await db.get(CanonicalArtist, canonical_id)
        if canonical is None or canonical.mbid is not None:
            return

        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                candidates = await search_artist(canonical.canonical_name, client=client)
                status, winner = decide_match(candidates, canonical.canonical_name)
                if status != "matched" or winner is None:
                    return
                canonical.mbid = winner.mbid
                await _register_alias_if_new(db, canonical, winner.name, source="musicbrainz")
                await _fetch_and_store_group_relations(db, canonical, client)
                await _register_wikidata_korean_alias(db, canonical, client)
                await _register_artist_image(db, canonical, client)
        except Exception as e:
            logger.warning(f"관리자 추가 아티스트 MusicBrainz 연결 실패, 건너뜀 ({canonical.canonical_name}): {e}")
            return

        await db.commit()
        logger.info(f"관리자 추가 아티스트 MusicBrainz 연결 완료: {canonical.canonical_name} -> {winner.name}")


# 표시명 후보 목록 - canonical_name(MusicBrainz 원문, 항상 포함) + 그동안 등록된 alias 전부
# (source: musicbrainz/wikidata/user_input/admin). admin 페이지 드롭다운에 그대로 씀
async def _name_options_for_canonical(db: AsyncSession, canonical: CanonicalArtist) -> list[dict]:
    alias_rows = (
        await db.execute(
            select(ArtistAlias.alias_text, ArtistAlias.source).where(
                ArtistAlias.canonical_artist_id == canonical.id
            )
        )
    ).all()
    options = {canonical.canonical_name: "canonical"}
    for text, source in alias_rows:
        options.setdefault(text, source)
    return [{"text": text, "source": source} for text, source in options.items()]


# admin 페이지가 이름 하나(concert.artist_name에 뜬 문자열)로 canonical을 찾아 표시명 후보를
# 보여줄 때 씀 - find_canonical_by_alias와 동일한 방식으로 resolve(alias/canonical_name 둘 다 확인)
async def get_canonical_name_options(db: AsyncSession, name: str) -> tuple[CanonicalArtist, list[dict]] | None:
    canonical = await find_canonical_by_alias(db, name)
    if canonical is None:
        return None
    return canonical, await _name_options_for_canonical(db, canonical)


# display_name이 바뀔 때 이미 그 표기로 확정돼있는 콘서트들도 같이 갱신 - 안 하면 admin이
# 표시명을 바꿔도 새로 매치되는 콘서트에만 적용되고 기존 콘서트는 예전 표기로 남아 혼란스러움
async def _reapply_display_name(db: AsyncSession, old_value: str, new_value: str) -> None:
    if old_value == new_value:
        return
    concert_ids = (
        await db.execute(select(ConcertLineup.concert_id).distinct().where(ConcertLineup.artist == old_value))
    ).scalars().all()
    for concert_id in concert_ids:
        # 이 소급 반영은 admin이 그 콘서트 하나하나를 직접 검수한 게 아니라 표시명 변경의
        # 부수효과로 여러 콘서트에 걸쳐 일괄 적용되는 것 - 검수 상태는 초기화
        await apply_canonical_replacement(db, concert_id, old_value, new_value, clear_admin_review=True)


# admin이 여러 표기 중 하나를 화면 표시명으로 직접 선택 - canonical_name(매칭 키)은 안 건드리고
# display_name만 바꾼 뒤, 이미 이 아티스트가 확정돼있는 콘서트 전부에 소급 반영
async def set_display_name(db: AsyncSession, canonical_id, display_name: str) -> CanonicalArtist:
    canonical = await db.get(CanonicalArtist, canonical_id)
    if canonical is None:
        raise HTTPException(status_code=404, detail="아티스트를 찾을 수 없습니다.")

    display_name = display_name.strip()
    if not display_name:
        raise HTTPException(status_code=400, detail="표시명이 비어있습니다.")
    if is_blocklisted_artist_name(display_name):
        raise HTTPException(status_code=400, detail="표시명으로 쓸 수 없는 값입니다.")

    old_value = _display_value(canonical)
    canonical.display_name = display_name
    await _register_alias_if_new(db, canonical, display_name, source="admin")
    await _reapply_display_name(db, old_value, display_name)

    await db.commit()
    await db.refresh(canonical)
    return canonical


# 관리자 페이지(아티스트 상세)에서 이 아티스트의 별칭을 직접 추가 - 정규화 배치가 이후 같은
# 표기를 API 호출 없이 바로 이 canonical로 재사용하게 됨(find_canonical_by_alias 참고)
async def add_artist_alias(db: AsyncSession, canonical_id, alias_text: str) -> CanonicalArtist:
    canonical = await db.get(CanonicalArtist, canonical_id)
    if canonical is None:
        raise HTTPException(status_code=404, detail="아티스트를 찾을 수 없습니다.")

    alias_text = alias_text.strip()
    if not alias_text:
        raise HTTPException(status_code=400, detail="별칭이 비어있습니다.")
    if is_blocklisted_artist_name(alias_text):
        raise HTTPException(status_code=400, detail="별칭으로 쓸 수 없는 값입니다.")

    await _register_alias_if_new(db, canonical, alias_text, source="admin")
    await db.commit()
    await db.refresh(canonical)
    return canonical


# 관리자 페이지(아티스트 상세)에서 잘못 등록된 별칭(오타, 동명이인 등)을 직접 제거 - 지금
# 표시명으로 쓰이는 텍스트면 거절(그 표기를 다시 매칭할 방법이 없어짐, 표시명부터 바꾸게 함)
async def remove_artist_alias(db: AsyncSession, canonical_id, alias_id) -> CanonicalArtist:
    canonical = await db.get(CanonicalArtist, canonical_id)
    if canonical is None:
        raise HTTPException(status_code=404, detail="아티스트를 찾을 수 없습니다.")

    alias = await db.get(ArtistAlias, alias_id)
    if alias is None or alias.canonical_artist_id != canonical.id:
        raise HTTPException(status_code=404, detail="별칭을 찾을 수 없습니다.")
    if alias.alias_text.lower() == _display_value(canonical).lower():
        raise HTTPException(status_code=400, detail="현재 표시명으로 쓰이는 별칭은 삭제할 수 없습니다. 표시명을 먼저 바꿔주세요.")

    await db.delete(alias)
    await db.commit()
    await db.refresh(canonical)
    return canonical


# 관리자 페이지(아티스트 상세)에서 콘서트 맥락 없이 그룹<->멤버 관계를 직접 추가 - set_group_membership과
# 달리 콘서트의 artist_name에 있어야 한다는 제약이 없음(멤버가 아직 등장한 공연이 하나도 없어도 등록
# 가능). role="member"면 other_name이 canonical_id(그룹)의 멤버로, role="group"이면 other_name이
# canonical_id(멤버)가 속한 그룹으로 등록된다
async def add_group_relation(db: AsyncSession, canonical_id, other_name: str, role: str) -> CanonicalArtist:
    canonical = await db.get(CanonicalArtist, canonical_id)
    if canonical is None:
        raise HTTPException(status_code=404, detail="아티스트를 찾을 수 없습니다.")

    other_name = other_name.strip()
    if not other_name:
        raise HTTPException(status_code=400, detail="아티스트명이 비어있습니다.")
    if is_blocklisted_artist_name(other_name):
        raise HTTPException(status_code=400, detail="아티스트명으로 쓸 수 없는 값입니다.")

    # add_artist_name/set_group_membership과 동일한 퍼지매칭 재사용 후 없으면 새로 생성
    existing_canonicals = (await db.execute(select(CanonicalArtist))).scalars().all()
    canonical_names = {c.canonical_name for c in existing_canonicals}
    resolved_name = normalize_artist_names([other_name], canonical_names)[0]

    other = next((c for c in existing_canonicals if c.canonical_name == resolved_name), None)
    if other is None:
        other = CanonicalArtist(mbid=None, canonical_name=resolved_name)
        db.add(other)
        await db.flush()
    await _register_alias_if_new(db, other, other_name, source="admin")

    if other.id == canonical.id:
        raise HTTPException(status_code=400, detail="자기 자신을 멤버/그룹으로 등록할 수 없습니다.")

    if role == "member":
        await _register_membership_if_new(db, other.id, canonical.id, source="admin")
    else:
        await _register_membership_if_new(db, canonical.id, other.id, source="admin")

    await db.commit()
    await db.refresh(canonical)
    return canonical


# 위 추가의 반대 - canonical_id와 other_id 사이의 관계를 방향 상관없이 완전히 지운다. 탈퇴 멤버
# 표시(is_current=False)와는 다른 케이스라 그쪽 필드는 안 쓰고 row 자체를 삭제함(잘못 등록된
# 관계를 바로잡는 용도라 "예전엔 맞았다"는 이력을 남길 이유가 없음)
async def remove_group_relation(db: AsyncSession, canonical_id, other_id) -> CanonicalArtist:
    canonical = await db.get(CanonicalArtist, canonical_id)
    if canonical is None:
        raise HTTPException(status_code=404, detail="아티스트를 찾을 수 없습니다.")

    rows = (
        await db.execute(
            select(ArtistGroupMembership).where(
                or_(
                    and_(
                        ArtistGroupMembership.member_canonical_id == canonical_id,
                        ArtistGroupMembership.group_canonical_id == other_id,
                    ),
                    and_(
                        ArtistGroupMembership.member_canonical_id == other_id,
                        ArtistGroupMembership.group_canonical_id == canonical_id,
                    ),
                )
            )
        )
    ).scalars().all()
    for row in rows:
        await db.delete(row)

    await db.commit()
    await db.refresh(canonical)
    return canonical


# concerts.artist_name 중 하나라도 names와 겹치는 공연이 있는지 - "이 아티스트가 아직 어딘가
# 등장하는지" 확인용(unused 판정/삭제 안전장치 공용)
async def _artist_still_referenced(db: AsyncSession, names: set[str]) -> bool:
    if not names:
        return False
    result = await db.execute(select(Concert.id).where(Concert.artist_name.overlap(list(names))).limit(1))
    return result.first() is not None


# 관리자 페이지(아티스트 상세)에서 잘못 만들어진 canonical을 DB에서 완전히 삭제 - concert에서
# 이름만 지우는 remove_artist_name과 달리 canonical_artists/artist_aliases(cascade)/
# artist_group_memberships(양방향)까지 지운다. 어느 공연에든 아직 등장하면 거절(먼저 그
# 공연들에서 이름을 지우고 오게 함) - 콘서트 표기와 canonical/별칭 링크가 안 어긋나게 함.
async def delete_canonical_artist(db: AsyncSession, canonical_id) -> None:
    canonical = await db.get(CanonicalArtist, canonical_id)
    if canonical is None:
        raise HTTPException(status_code=404, detail="아티스트를 찾을 수 없습니다.")

    alias_texts = (
        await db.execute(select(ArtistAlias.alias_text).where(ArtistAlias.canonical_artist_id == canonical_id))
    ).scalars().all()
    own_names = {canonical.canonical_name} | set(alias_texts)

    if await _artist_still_referenced(db, own_names):
        raise HTTPException(
            status_code=400, detail="아직 공연에 등장하는 아티스트입니다. 먼저 해당 공연에서 이름을 지워주세요."
        )

    membership_result = await db.execute(
        select(ArtistGroupMembership).where(
            or_(
                ArtistGroupMembership.member_canonical_id == canonical_id,
                ArtistGroupMembership.group_canonical_id == canonical_id,
            )
        )
    )
    for row in membership_result.scalars().all():
        await db.delete(row)

    await db.delete(canonical)  # ArtistAlias는 cascade="all, delete-orphan"으로 같이 삭제됨
    await db.commit()


# 매치된 멤버들의 그룹 로스터와 대조해 사실상 그룹 전체 공연이면 멤버 표기 대신 그룹명으로
# 정리한다. 그룹명이 이미 있거나 로스터 전원이 있으면 바로, 1명이라도 빠졌으면 concert.name에
# 그룹명이 언급될 때만 허용(추출 누락으로 간주) - 근거 없이 안 오는 사람까지 왔다고 하는 게 더 위험함
async def _collapse_members_to_group_names(db: AsyncSession, concert_id) -> None:
    concert = await db.get(Concert, concert_id)
    if concert is None or not concert.artist_name:
        return

    names = list(concert.artist_name)
    canonical_result = await db.execute(
        select(CanonicalArtist).where(CanonicalArtist.canonical_name.in_(names))
    )
    canonical_by_name = {c.canonical_name: c for c in canonical_result.scalars().all()}
    canonical_ids = {c.id for c in canonical_by_name.values()}
    if not canonical_ids:
        return

    membership_result = await db.execute(
        select(ArtistGroupMembership).where(
            ArtistGroupMembership.is_current.is_(True),
            ArtistGroupMembership.member_canonical_id.in_(canonical_ids),
        )
    )
    candidate_group_ids = {m.group_canonical_id for m in membership_result.scalars().all()}
    if not candidate_group_ids:
        return

    changed = False
    for group_id in candidate_group_ids:
        group = await db.get(CanonicalArtist, group_id)
        if group is None:
            continue

        roster_result = await db.execute(
            select(ArtistGroupMembership.member_canonical_id).where(
                ArtistGroupMembership.group_canonical_id == group_id,
                ArtistGroupMembership.is_current.is_(True),
            )
        )
        roster_ids = set(roster_result.scalars().all())
        present_member_ids = roster_ids & canonical_ids
        if not present_member_ids:
            continue

        group_name_present = group.canonical_name in names
        all_members_present = bool(roster_ids) and present_member_ids == roster_ids
        title_mentions_group = group.canonical_name in (concert.name or "")
        if not (group_name_present or all_members_present or title_mentions_group):
            continue

        present_member_names = {n for n, c in canonical_by_name.items() if c.id in present_member_ids}
        new_names = (set(names) - present_member_names) | {group.canonical_name}
        if new_names != set(names):
            names = sorted(new_names)
            changed = True

    if changed:
        concert.artist_name = names
        concert.admin_reviewed_at = None


# canonical의 mbid로 Wikidata 항목을 찾아 한글 label을 alias로 등록(예: Konomi Suzuki →
# "스즈키 코노미"). KOPIS 원본이 같은 한글 표기로 큐잉돼 있으면 재검색 없이 이 alias로
# 바로 matched됨 - "포스터엔 원어, KOPIS엔 한글 음차"로 나뉘어 영구 unconfirmed로 남던
# 케이스 구제용. 이미 alias 있으면 재조회 안 함, 조회 실패는 조용히 건너뜀(보강 데이터라 무해).
async def _register_wikidata_korean_alias(db: AsyncSession, canonical: CanonicalArtist, client: httpx.AsyncClient) -> None:
    if not canonical.mbid:
        return
    existing = await db.execute(
        select(ArtistAlias.id).where(
            ArtistAlias.canonical_artist_id == canonical.id, ArtistAlias.source == "wikidata"
        )
    )
    if existing.scalar_one_or_none() is not None:
        return

    try:
        qid = await fetch_wikidata_qid(canonical.mbid, client)
        if qid is None:
            return
        label = await fetch_korean_label(qid, client)
    except Exception as e:
        logger.warning(f"Wikidata 한글 별칭 보강 실패, 건너뜀 (mbid={canonical.mbid}): {e}")
        return

    if not label:
        return
    await _register_alias_if_new(db, canonical, label, source="wikidata")
    if canonical.display_name is None:
        # 최초로 한글 label을 얻은 시점에만 자동으로 표시명을 채택 - 이후 admin이 수동으로
        # 바꾸면(set_display_name) 여기가 다시 안 도니 덮어쓸 일 없음
        canonical.display_name = label


# canonical의 mbid로 아티스트 사진을 찾아 저장한다. MusicBrainz가 연결해둔 Spotify 링크
# 우선(앨범아트 수준), 없으면 Wikidata 대표 이미지(P18)로 대체 - 둘 다 mbid 앵커라 이름
# 검색(Deezer 등, 오매칭 실측 확인됨)과 달리 동명이인 위험 없음. 이미 있으면 재조회 안 함.
async def _register_artist_image(db: AsyncSession, canonical: CanonicalArtist, client: httpx.AsyncClient) -> None:
    if not canonical.mbid or canonical.profile_image_url:
        return

    try:
        image_url = None
        spotify_url = await fetch_spotify_artist_url(canonical.mbid, client)
        if spotify_url:
            image_url = await fetch_oembed_thumbnail(spotify_url, client)
        if image_url is None:
            qid = await fetch_wikidata_qid(canonical.mbid, client)
            if qid:
                image_url = await fetch_artist_image_url(qid, client)
    except Exception as e:
        logger.warning(f"아티스트 사진 보강 실패, 건너뜀 (mbid={canonical.mbid}): {e}")
        return

    if image_url:
        canonical.profile_image_url = image_url


async def _process_one(
    db: AsyncSession, client: httpx.AsyncClient, row: ArtistNormalizationStatus
) -> str:
    canonical = await find_canonical_by_alias(db, row.artist_text)
    if canonical is not None:
        if canonical.mbid is None:
            # mbid 없는 canonical은 admin이 수동 병합(예: 본명↔예명)으로 만든 것 - MusicBrainz
            # 검증이 없어 문자열만 같은 동명이인이면 오병합 위험(흔한 한국 이름 실측 우려로
            # 발견). 자동 적용 대신 admin 확인 대기 상태로만 표시
            row.status = "suggested"
            row.suggested_canonical_id = canonical.id
            return "suggested"
        await _register_wikidata_korean_alias(db, canonical, client)
        await _register_artist_image(db, canonical, client)
        await apply_canonical_replacement(
            db, row.concert_id, row.artist_text, _display_value(canonical), clear_admin_review=True
        )
        row.status = "matched"
        return "matched"

    candidates = await search_artist(row.artist_text, client=client)
    row.attempt_count += 1
    row.last_attempted_at = datetime.now(timezone.utc)

    status, winner = decide_match(candidates, row.artist_text)
    row.status = status

    if status == "matched" and winner is not None:
        canonical, created = await _get_or_create_canonical_by_mbid(db, winner.mbid, winner.name)
        await _register_alias_if_new(db, canonical, row.artist_text, source="musicbrainz")
        if created:
            await _fetch_and_store_group_relations(db, canonical, client)
        await _register_wikidata_korean_alias(db, canonical, client)
        await _register_artist_image(db, canonical, client)
        await apply_canonical_replacement(
            db, row.concert_id, row.artist_text, _display_value(canonical), clear_admin_review=True
        )

    return status


# row 목록을 순서대로 정규화 처리하며 결과를 집계(공통 루프). 실패(네트워크 오류 등)는
# status를 안 바꾸고 pending으로 남겨 다음 실행이 자동 재시도하게 함. commit_each_row=True
# (기본)면 매 행마다 바로 커밋 - 큰 실행을 한 트랜잭션에 담으면 "idle in transaction" 좀비
# 커넥션이 무관한 쿼리까지 막는 실장애가 있었음(dry_run은 False로 넘겨 전체 롤백 유지).
async def _process_rows(
    db: AsyncSession,
    client: httpx.AsyncClient,
    rows: list[ArtistNormalizationStatus],
    *,
    commit_each_row: bool = True,
) -> dict[str, int]:
    stats = {"processed": 0, "matched": 0, "unconfirmed": 0, "ambiguous": 0, "error": 0}
    for row in rows:
        try:
            status = await _process_one(db, client, row)
            stats[status] = stats.get(status, 0) + 1
        except Exception as e:
            logger.warning(f"아티스트 정규화 실패, pending 유지 (artist_text={row.artist_text!r}): {e}")
            stats["error"] += 1
            continue
        finally:
            if commit_each_row:
                await db.commit()
        stats["processed"] += 1
    return stats


# 정규화 대기열(pending)을 소비하는 배치 본체 (스케줄러가 매일 밤 전체 큐 대상으로 호출)
async def normalize_pending_artists(limit: int = _DEFAULT_BATCH_LIMIT, *, dry_run: bool = False) -> dict[str, int]:
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
            return {"processed": 0, "matched": 0, "unconfirmed": 0, "ambiguous": 0, "error": 0}

        # 한글 표기를 뒤로 미룸(created_at 순서는 유지, stable sort) - 같은 콘서트의 원어
        # 표기가 먼저 matched되면 그 자리에서 Wikidata 한글 alias가 등록되니, 한글 probe(KOPIS
        # 원본) 표기가 그 뒤에 처리되면 재검색 없이 바로 그 alias로 matched됨. 순서를 안 바꾸면
        # 한글 쪽이 먼저 뽑혀서 이 회차엔 놓치고 unconfirmed로 영구 고정될 수 있음(재시도 없음)
        rows = sorted(rows, key=lambda r: _contains_hangul(r.artist_text))

        logger.info(f"MusicBrainz 정규화 대상 {len(rows)}건")
        async with httpx.AsyncClient(timeout=10.0) as client:
            stats = await _process_rows(db, client, rows, commit_each_row=not dry_run)

        for concert_id in {row.concert_id for row in rows}:
            await _collapse_members_to_group_names(db, concert_id)

        if dry_run:
            await db.rollback()
            logger.info(f"[dry-run] 커밋하지 않고 롤백함: {stats}")
        else:
            await db.commit()
            logger.info(f"MusicBrainz 정규화 완료: {stats}")

    return stats


# 웹훅 도착 직후 "이번에 새로 큐잉된 이름들"만 즉시 정규화 - fire-and-forget 백그라운드
# 태스크로 호출(웹훅 응답 이후 실행, 응답을 기다리게 하지 않음). pending 전체를 훑는
# normalize_pending_artists와 달리 이 콘서트의 이 이름들로만 좁혀서 무관한 콘서트는 안 건드림
async def normalize_specific_artists(concert_id, names: list[str]) -> dict[str, int]:
    if not names:
        return {"processed": 0, "matched": 0, "unconfirmed": 0, "ambiguous": 0, "error": 0}

    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(ArtistNormalizationStatus).where(
                ArtistNormalizationStatus.concert_id == concert_id,
                ArtistNormalizationStatus.artist_text.in_(names),
                ArtistNormalizationStatus.status == "pending",
            )
        )
        rows = result.scalars().all()
        if not rows:
            return {"processed": 0, "matched": 0, "unconfirmed": 0, "ambiguous": 0, "error": 0}

        async with httpx.AsyncClient(timeout=10.0) as client:
            stats = await _process_rows(db, client, rows)

        await _collapse_members_to_group_names(db, concert_id)

        await db.commit()
        logger.info(f"MusicBrainz 즉시 정규화 완료 (concert_id={concert_id}): {stats}")

    return stats
