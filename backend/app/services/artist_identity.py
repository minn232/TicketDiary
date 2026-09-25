import asyncio
import logging
from datetime import datetime, timezone
from uuid import UUID

import httpx
from fastapi import HTTPException
from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.artist_identity import ArtistIdentityChange, ConcertArtistLink
from app.models.artist_normalization import ArtistAlias, CanonicalArtist
from app.models.concert import Concert
from app.models.user import User
from app.services.artist_normalization import (
    _alternate_lookup_names,
    _fetch_and_store_group_relations,
    _get_or_create_canonical_by_mbid,
    _register_artist_image,
    _register_wikidata_korean_alias,
    find_canonical_by_alias,
)
from app.services.musicbrainz import fetch_artist_detail, search_artist_detailed

logger = logging.getLogger(__name__)


async def get_concert_link(db: AsyncSession, concert_id: UUID | None, artist: str) -> ConcertArtistLink | None:
    if concert_id is None:
        return None
    result = await db.execute(
        select(ConcertArtistLink).where(
            ConcertArtistLink.concert_id == concert_id, ConcertArtistLink.artist_text == artist
        )
    )
    return result.scalar_one_or_none()


# 공연 안에서 이 표기가 가리키는 canonical - 공연별 연결이 있으면 그게 우선, 없으면 전역 별칭 -
# 두 번째 값이 True면 "연결할 아티스트 없음"으로 확정된 것(호출부는 대표곡/셋리 검색을 건너뜀)
async def resolve_concert_artist(
    db: AsyncSession, concert_id: UUID | None, artist: str
) -> tuple[CanonicalArtist | None, bool]:
    link = await get_concert_link(db, concert_id, artist)
    if link is not None:
        if link.canonical_id is None:
            return None, True
        return await db.get(CanonicalArtist, link.canonical_id), False
    return await find_canonical_by_alias(db, artist), False


async def _concert_with_artist(db: AsyncSession, concert_id: UUID, artist: str) -> Concert:
    concert = await db.get(Concert, concert_id)
    if concert is None:
        raise HTTPException(status_code=404, detail="공연 정보를 찾을 수 없습니다.")
    if artist not in (concert.artist_name or []):
        raise HTTPException(status_code=400, detail="해당 아티스트가 이 공연에 없습니다.")
    return concert


def canonical_summary(canonical: CanonicalArtist | None) -> dict | None:
    if canonical is None:
        return None
    return {
        "canonical_id": canonical.id,
        "mbid": canonical.mbid,
        "name": canonical.display_name or canonical.canonical_name,
        "image_url": canonical.profile_image_url,
    }


# 연결 수정 후보 - 우리 DB에 이미 있는 같은 이름(별칭/표시명 포함, 사진 있음)을 먼저, 그다음
# MusicBrainz 검색 결과 중 DB에 없는 것 - 동명이인 구분용으로 국가/유형/설명/활동 시작 연도/곡 몇 개를 붙임
async def identity_candidates(db: AsyncSession, concert_id: UUID, artist: str) -> dict:
    await _concert_with_artist(db, concert_id, artist)
    current, no_artist = await resolve_concert_artist(db, concert_id, artist)

    lowered = [n.strip().lower() for n in [artist, *_alternate_lookup_names(artist)]]
    alias_ids = select(ArtistAlias.canonical_artist_id).where(func.lower(ArtistAlias.alias_text).in_(lowered))
    db_rows = (
        await db.execute(
            select(CanonicalArtist).where(
                or_(
                    func.lower(CanonicalArtist.canonical_name).in_(lowered),
                    func.lower(CanonicalArtist.display_name).in_(lowered),
                    CanonicalArtist.id.in_(alias_ids),
                )
            )
        )
    ).scalars().all()
    if current is not None and all(c.id != current.id for c in db_rows):
        db_rows = [current, *db_rows]

    try:
        mb_results = await search_artist_detailed(artist)
    except httpx.HTTPError as e:
        logger.warning(f"MusicBrainz 후보 검색 실패 ({artist}): {e}")
        mb_results = []
    mb_by_id = {r["mbid"]: r for r in mb_results}

    candidates = []
    for canonical in db_rows:
        detail = mb_by_id.get(canonical.mbid or "", {})
        candidates.append({
            **canonical_summary(canonical),
            "country": detail.get("country"),
            "type": detail.get("type"),
            "disambiguation": detail.get("disambiguation"),
            "begin_year": detail.get("begin_year"),
            "is_current": current is not None and canonical.id == current.id,
        })
    known_mbids = {c.mbid for c in db_rows if c.mbid}
    for r in mb_results:
        if r["mbid"] not in known_mbids:
            candidates.append({
                "canonical_id": None,
                "mbid": r["mbid"],
                "name": r["name"],
                "image_url": None,
                "country": r["country"],
                "type": r["type"],
                "disambiguation": r["disambiguation"],
                "begin_year": r["begin_year"],
                "is_current": False,
            })

    from app.services.representative_songs import candidate_top_songs  # 순환 임포트 방지용 지연 임포트

    itunes_ids = {c.id: c.itunes_artist_id for c in db_rows}
    songs = await asyncio.gather(*(
        candidate_top_songs(c["mbid"], itunes_ids.get(c["canonical_id"])) for c in candidates
    ))
    for candidate, top_songs in zip(candidates, songs):
        candidate["top_songs"] = top_songs
    return {"artist": artist, "current": canonical_summary(current), "no_artist": no_artist, "candidates": candidates}


# MusicBrainz 후보를 골랐을 때 - 없던 아티스트면 정규화와 같은 방식으로 만들고 사진/한글 표시명을 채움
async def _canonical_from_mbid(db: AsyncSession, mbid: str) -> CanonicalArtist:
    detail = await fetch_artist_detail(mbid)
    if detail is None:
        raise HTTPException(status_code=400, detail="MusicBrainz 아티스트를 찾을 수 없습니다.")
    canonical, created = await _get_or_create_canonical_by_mbid(db, detail["mbid"], detail["name"])
    async with httpx.AsyncClient(timeout=10.0) as client:
        if created:
            await _fetch_and_store_group_relations(db, canonical, client)
        await _register_wikidata_korean_alias(db, canonical, client)
        await _register_artist_image(db, canonical, client)
    return canonical


# 이 공연의 아티스트 표기를 다른 아티스트로(또는 "없음"으로) 바로 연결하고 기록을 남김 - 전역 별칭은
# 안 건드려서 같은 이름의 다른 공연(동명이인일 수 있음)엔 영향 없음, 이미 같은 연결이면 기록 없이 그대로
async def change_concert_artist_identity(
    db: AsyncSession,
    concert_id: UUID,
    artist: str,
    *,
    canonical_id: UUID | None = None,
    mbid: str | None = None,
    no_artist: bool = False,
    user_id: UUID | None = None,
    source: str = "user",
) -> CanonicalArtist | None:
    await _concert_with_artist(db, concert_id, artist)
    if sum([canonical_id is not None, bool(mbid), no_artist]) != 1:
        raise HTTPException(status_code=400, detail="연결할 아티스트를 하나만 골라주세요.")

    if canonical_id is not None:
        target = await db.get(CanonicalArtist, canonical_id)
        if target is None:
            raise HTTPException(status_code=404, detail="대상 아티스트를 찾을 수 없습니다.")
    elif mbid:
        target = await _canonical_from_mbid(db, mbid)
    else:
        target = None

    link = await get_concert_link(db, concert_id, artist)
    if link is not None:
        before_id = link.canonical_id
    else:
        global_canonical = await find_canonical_by_alias(db, artist)
        before_id = global_canonical.id if global_canonical is not None else None
    after_id = target.id if target is not None else None
    if link is not None and before_id == after_id:
        return target

    now = datetime.now(timezone.utc)
    if link is None:
        db.add(ConcertArtistLink(concert_id=concert_id, artist_text=artist, canonical_id=after_id, updated_at=now))
    else:
        link.canonical_id = after_id
        link.updated_at = now
    db.add(ArtistIdentityChange(
        concert_id=concert_id,
        artist_text=artist,
        before_canonical_id=before_id,
        before_was_link=link is not None,
        after_canonical_id=after_id,
        changed_by_user_id=user_id,
        source=source,
        created_at=now,
    ))
    await db.commit()
    return target


# 관리자 되돌리기 - 같은 공연/표기의 가장 최근 변경만 되돌릴 수 있음(중간 것을 되돌리면 기록이 꼬임)
async def revert_identity_change(db: AsyncSession, change_id: UUID) -> ArtistIdentityChange:
    change = await db.get(ArtistIdentityChange, change_id)
    if change is None:
        raise HTTPException(status_code=404, detail="변경 기록을 찾을 수 없습니다.")
    if change.reverted_at is not None:
        raise HTTPException(status_code=409, detail="이미 되돌린 변경입니다.")
    latest = (
        await db.execute(
            select(ArtistIdentityChange)
            .where(
                ArtistIdentityChange.concert_id == change.concert_id,
                ArtistIdentityChange.artist_text == change.artist_text,
                ArtistIdentityChange.reverted_at.is_(None),
            )
            .order_by(ArtistIdentityChange.created_at.desc())
            .limit(1)
        )
    ).scalar_one()
    if latest.id != change.id:
        raise HTTPException(status_code=409, detail="더 최근 변경이 있어요. 최근 것부터 되돌려주세요.")

    link = await get_concert_link(db, change.concert_id, change.artist_text)
    if change.before_was_link:
        if link is None:
            db.add(ConcertArtistLink(
                concert_id=change.concert_id, artist_text=change.artist_text,
                canonical_id=change.before_canonical_id, updated_at=datetime.now(timezone.utc),
            ))
        else:
            link.canonical_id = change.before_canonical_id
    elif link is not None:
        await db.delete(link)
    change.reverted_at = datetime.now(timezone.utc)
    await db.commit()
    return change


# 변경 기록(최신순) - change_id를 주면 그 한 건만
async def list_identity_changes(db: AsyncSession, limit: int = 50, change_id: UUID | None = None) -> list[dict]:
    query = (
        select(ArtistIdentityChange, Concert.name, Concert.kopis_id, User.nickname)
        .join(Concert, Concert.id == ArtistIdentityChange.concert_id)
        .outerjoin(User, User.id == ArtistIdentityChange.changed_by_user_id)
        .order_by(ArtistIdentityChange.created_at.desc())
        .limit(limit)
    )
    if change_id is not None:
        query = query.where(ArtistIdentityChange.id == change_id)
    rows = (await db.execute(query)).all()
    ids = {c.before_canonical_id for c, *_ in rows} | {c.after_canonical_id for c, *_ in rows}
    ids.discard(None)
    canonicals = {}
    if ids:
        for canonical in (await db.execute(select(CanonicalArtist).where(CanonicalArtist.id.in_(ids)))).scalars():
            canonicals[canonical.id] = canonical
    return [
        {
            "id": change.id,
            "concert_id": change.concert_id,
            "concert_name": concert_name,
            "kopis_id": kopis_id,
            "artist_text": change.artist_text,
            "before": canonical_summary(canonicals.get(change.before_canonical_id)),
            "after": canonical_summary(canonicals.get(change.after_canonical_id)),
            "source": change.source,
            "changed_by": nickname,
            "created_at": change.created_at,
            "reverted_at": change.reverted_at,
        }
        for change, concert_name, kopis_id, nickname in rows
    ]
