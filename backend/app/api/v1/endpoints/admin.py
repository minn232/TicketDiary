from datetime import datetime, timezone
from pathlib import Path
from uuid import UUID

from fastapi import APIRouter, BackgroundTasks, Depends, File, HTTPException, Query, Request, UploadFile
from fastapi.responses import HTMLResponse
from sqlalchemy import and_, func, not_, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import verify_admin_key
from app.models.artist_normalization import (
    ArtistAlias,
    ArtistGroupMembership,
    ArtistNormalizationStatus,
    CanonicalArtist,
)
from app.models.concert import Concert, EventType
from app.schemas.admin import (
    AdminAddAliasRequest,
    AdminArtistAddRequest,
    AdminArtistConcertItem,
    AdminArtistDetail,
    AdminArtistListItem,
    AdminArtistListResponse,
    AdminArtistRenameRequest,
    AdminArtistSuggestionRequest,
    AdminCanonicalNameOptions,
    AdminConcertDetail,
    AdminConcertListItem,
    AdminConcertListResponse,
    AdminCrawlScreenshotUploadResponse,
    AdminCrawlTargetCandidate,
    AdminCrawlTargetItem,
    AdminCrawlTargetsResponse,
    AdminDisplayNameRequest,
    AdminGroupMembershipRequest,
    AdminGroupRelationAddRequest,
    AdminReassignArtistRequest,
    AdminRegisterNewArtistRequest,
)
from app.services.artist_blocklist import add_to_blocklist
from app.services.artist_normalization import (
    _display_value,
    add_artist_alias,
    add_artist_name,
    add_group_relation,
    confirm_artist_name_change,
    delete_canonical_artist,
    get_canonical_name_options,
    reassign_artist_to_canonical,
    register_new_canonical_artist,
    remove_artist_alias,
    remove_artist_name,
    remove_group_relation,
    resolve_artist_suggestion,
    set_display_name,
    set_group_membership,
    try_link_canonical_to_musicbrainz,
)
from app.services.crawler import (
    _ARTIST_EXTRACTION_RETRY_COOLDOWN,
    _MAX_ARTIST_EXTRACTION_ATTEMPTS,
    get_yes24_melon_crawl_targets,
    save_manual_crawl_screenshot,
)

router = APIRouter(dependencies=[Depends(verify_admin_key)])

_DEFAULT_PAGE_SIZE = 20


# 콘서트명/kopis_id/아티스트명 어디든 걸리는 느슨한 검색 - artist_name이 배열이라 콤마로
# 이어붙인 문자열로 만들어 통째로 ILIKE (정확한 아티스트 단위 검색이 아니라 훑어보기용)
def _search_filter(keyword: str):
    like = f"%{keyword}%"
    joined_artists = func.array_to_string(Concert.artist_name, ",")
    return or_(Concert.name.ilike(like), Concert.kopis_id.ilike(like), joined_artists.ilike(like))


# "크롤링 스크린샷을 LLM_CRAWL_URL로 보내는" 경로(send_screenshots_to_llm)의 대상 여부.
# crawl_screenshot_url만 있으면 매일 밤 전부 보내고 응답의 artist_name은 병합됨(/crawl-result
# 웹훅). crawl_screenshot_url은 찜/티켓등록 시점이나 재시도 배치로 채워지고, FESTIVAL이면
# 크롤링 전이어도 라인업 재확인 배치가 채움 - "4명 이상이면 이미 페스티벌"이라는 가정은
# 틀려서(승격 기준은 THRESHOLD=5) event_type을 직접 봐야 사각지대가 없다.
def _auto_covered_by_crawl_filter():
    return or_(
        Concert.crawl_screenshot_url.isnot(None),
        Concert.event_type == EventType.FESTIVAL.value,
    )


# 관리자 페이지 "자동 채움 안 되는 공연만 보기" 필터(unsent_to_llm_only)가 이 조건으로 골라냄.
# 포스터 파이프라인의 자체 대상 조건(장르/4명 미만/포스터 있음/쿨다운)은 일부러 안 봄 - 같이
# 걸면 사실상 "4명에서 멈춘 공연"만 남아 의미가 흐려짐(장르는 대중음악 전용이라 항상 통과,
# 포스터 없음/재시도 소진은 드묾). 크롤링 경로에 걸리는지만으로 판단해 "크롤링 쪽으로도 안
# 넘어간다"는 사실만 명확히 보여줌.
def _needs_manual_artist_fill_filter():
    return not_(_auto_covered_by_crawl_filter())


# 크롤링 경로 대상이면(_auto_covered_by_crawl_filter) 아래 포스터 쪽 사유는 참고용으로도
# 무의미하므로 빈 리스트 반환. 필터 자체는 더 이상 이 사유들을 안 보지만, 배지로는 여전히
# "포스터 파이프라인이 왜 이 공연을 더 안 건드리는지" 참고 정보로 보여줌
def _llm_exclusion_reasons(concert: Concert, now: datetime) -> list[str]:
    if concert.crawl_screenshot_url is not None:
        return []
    if concert.event_type == EventType.FESTIVAL.value:
        return []

    reasons = []
    if "대중음악" not in (concert.genre or []):
        reasons.append("장르가 대중음악 아님")
    if len(concert.artist_name or []) >= 4:
        reasons.append("아티스트 4명 이상")
    if not concert.poster_url:
        reasons.append("포스터 없음")
    attempted_at = concert.artist_extraction_attempted_at
    if attempted_at is not None:
        if concert.artist_extraction_attempt_count >= _MAX_ARTIST_EXTRACTION_ATTEMPTS:
            reasons.append("재시도 상한 도달")
        elif now - attempted_at < _ARTIST_EXTRACTION_RETRY_COOLDOWN:
            reasons.append("쿨다운 대기 중")
    return reasons


@router.get("/concerts", response_model=AdminConcertListResponse)
async def list_concerts(
    search: str | None = Query(None),
    flagged_only: bool = Query(False),
    unsent_to_llm_only: bool = Query(False),
    unreviewed_only: bool = Query(False),
    ai_reviewed_only: bool = Query(False),
    upcoming_only: bool = Query(False),
    page: int = Query(1, ge=1),
    page_size: int = Query(_DEFAULT_PAGE_SIZE, ge=1, le=100),
    db: AsyncSession = Depends(get_db),
):
    now = datetime.now(timezone.utc)
    flagged_concert_ids = select(ArtistNormalizationStatus.concert_id).where(
        ArtistNormalizationStatus.status.in_(["unconfirmed", "ambiguous", "suggested"])
    )

    query = select(Concert)
    if search:
        query = query.where(_search_filter(search))
    if flagged_only:
        query = query.where(Concert.id.in_(flagged_concert_ids))
    if unsent_to_llm_only:
        query = query.where(_needs_manual_artist_fill_filter())
    if unreviewed_only:
        # 사람 검수도 Claude 검수도 안 된 것만 - AI 검수완료는 이 탭에서 빠지고 ai_reviewed_only로 따로 봄
        query = query.where(Concert.admin_reviewed_at.is_(None), Concert.ai_reviewed_at.is_(None))
    if ai_reviewed_only:
        query = query.where(Concert.ai_reviewed_at.isnot(None))
    if upcoming_only:
        # 다른 곳(concert_search.py 등)과 동일 기준(end_date > now) - 이미 끝난 공연은
        # 우선순위가 낮으므로 admin이 검수 대상에서 제외해서 볼 수 있게
        query = query.where(Concert.end_date > now)

    total = (await db.execute(select(func.count()).select_from(query.subquery()))).scalar_one()

    query = query.order_by(Concert.start_date.desc()).offset((page - 1) * page_size).limit(page_size)
    concerts = (await db.execute(query)).scalars().all()

    flag_counts: dict[UUID, int] = {}
    if concerts:
        concert_ids = [c.id for c in concerts]
        rows = await db.execute(
            select(ArtistNormalizationStatus.concert_id, func.count())
            .where(
                ArtistNormalizationStatus.concert_id.in_(concert_ids),
                ArtistNormalizationStatus.status.in_(["unconfirmed", "ambiguous", "suggested"]),
            )
            .group_by(ArtistNormalizationStatus.concert_id)
        )
        flag_counts = dict(rows.all())

    items = [
        AdminConcertListItem(
            id=c.id,
            kopis_id=c.kopis_id,
            name=c.name,
            artist_name=c.artist_name,
            poster_url=c.poster_url,
            start_date=c.start_date,
            flagged_count=flag_counts.get(c.id, 0),
            llm_exclusion_reasons=_llm_exclusion_reasons(c, now),
            admin_reviewed_at=c.admin_reviewed_at,
            ai_reviewed_at=c.ai_reviewed_at,
        )
        for c in concerts
    ]
    return AdminConcertListResponse(items=items, total=total, page=page, page_size=page_size)


@router.get("/concerts/{concert_id}", response_model=AdminConcertDetail)
async def get_concert_detail(concert_id: UUID, db: AsyncSession = Depends(get_db)):
    concert = await db.get(Concert, concert_id)
    if concert is None:
        raise HTTPException(status_code=404, detail="공연 정보를 찾을 수 없습니다.")

    status_rows = (
        await db.execute(
            select(ArtistNormalizationStatus).where(ArtistNormalizationStatus.concert_id == concert_id)
        )
    ).scalars().all()

    # suggested 상태 행이 있으면 제안 중인 canonical의 표시명도 같이 내려줘서 프론트가 "OOO와
    # 같은 사람?"을 바로 보여줄 수 있게 함(추가 조회 왕복 없이)
    suggested_ids = {r.suggested_canonical_id for r in status_rows if r.suggested_canonical_id}
    suggested_names: dict = {}
    if suggested_ids:
        suggested_result = await db.execute(select(CanonicalArtist).where(CanonicalArtist.id.in_(suggested_ids)))
        suggested_names = {c.id: _display_value(c) for c in suggested_result.scalars().all()}

    return AdminConcertDetail(
        id=concert.id,
        kopis_id=concert.kopis_id,
        name=concert.name,
        artist_name=concert.artist_name,
        poster_url=concert.poster_url,
        venue=concert.venue,
        start_date=concert.start_date,
        event_type=concert.event_type,
        ticketing_links=concert.ticketing_links,
        statuses=[
            {
                "artist_text": r.artist_text,
                "status": r.status,
                "attempt_count": r.attempt_count,
                "suggested_name": suggested_names.get(r.suggested_canonical_id),
            }
            for r in status_rows
        ],
        group_memberships=await _group_memberships_for(db, concert.artist_name),
        admin_reviewed_at=concert.admin_reviewed_at,
        ai_reviewed_at=concert.ai_reviewed_at,
    )


# admin이 이 공연을 수정하거나 "검수 완료"를 직접 눌렀을 때 호출 - 자동 파이프라인이 나중에
# artist_name을 바꾸면(crawl.py 웹훅, 정규화 배치) 이 값은 다시 NULL로 초기화됨
async def _mark_reviewed(db: AsyncSession, concert_id: UUID) -> None:
    concert = await db.get(Concert, concert_id)
    if concert is None:
        raise HTTPException(status_code=404, detail="공연 정보를 찾을 수 없습니다.")
    concert.admin_reviewed_at = datetime.now(timezone.utc)
    await db.commit()


# artist_name 중 밴드로 알려진 이름 -> 현재 멤버명 목록. 밴드 표기 옆에 "멤버: A, B, C"를
# 보여주기 위한 조회(set_group_membership으로 등록된 관계 포함, 자동/수동 출처 구분 안 함)
async def _group_memberships_for(db: AsyncSession, artist_name: list[str]) -> dict[str, list[str]]:
    if not artist_name:
        return {}
    canonical_result = await db.execute(
        select(CanonicalArtist).where(CanonicalArtist.canonical_name.in_(artist_name))
    )
    canonicals_by_name = {c.canonical_name: c for c in canonical_result.scalars().all()}
    if not canonicals_by_name:
        return {}

    group_ids = [c.id for c in canonicals_by_name.values()]
    membership_result = await db.execute(
        select(ArtistGroupMembership.group_canonical_id, CanonicalArtist.canonical_name)
        .join(CanonicalArtist, CanonicalArtist.id == ArtistGroupMembership.member_canonical_id)
        .where(
            ArtistGroupMembership.group_canonical_id.in_(group_ids),
            ArtistGroupMembership.is_current.is_(True),
        )
    )
    members_by_group_id: dict = {}
    for group_id, member_name in membership_result.all():
        members_by_group_id.setdefault(group_id, []).append(member_name)

    return {
        name: sorted(members_by_group_id[c.id])
        for name, c in canonicals_by_name.items()
        if c.id in members_by_group_id
    }


@router.post("/concerts/{concert_id}/artist-name", response_model=AdminConcertDetail)
async def add_artist(
    concert_id: UUID,
    body: AdminArtistAddRequest,
    background_tasks: BackgroundTasks,
    db: AsyncSession = Depends(get_db),
):
    _, canonical = await add_artist_name(db, concert_id, body.name)
    if canonical.mbid is None:
        # 응답 이후 백그라운드로 실행 - 스로틀(2초 간격) 때문에 여기서 기다리면 추가 자체가 느려짐
        background_tasks.add_task(try_link_canonical_to_musicbrainz, canonical.id)
    await _mark_reviewed(db, concert_id)
    return await get_concert_detail(concert_id, db)


@router.post("/concerts/{concert_id}/group-membership", response_model=AdminConcertDetail)
async def set_group_membership_route(
    concert_id: UUID, body: AdminGroupMembershipRequest, db: AsyncSession = Depends(get_db)
):
    await set_group_membership(db, concert_id, body.group_name, body.member_names)
    await _mark_reviewed(db, concert_id)
    return await get_concert_detail(concert_id, db)


@router.patch("/concerts/{concert_id}/artist-name", response_model=AdminConcertDetail)
async def rename_artist(concert_id: UUID, body: AdminArtistRenameRequest, db: AsyncSession = Depends(get_db)):
    await confirm_artist_name_change(db, concert_id, body.original_name, body.confirmed_name)
    await _mark_reviewed(db, concert_id)
    return await get_concert_detail(concert_id, db)


@router.post("/concerts/{concert_id}/artist-suggestion", response_model=AdminConcertDetail)
async def resolve_artist_suggestion_route(
    concert_id: UUID, body: AdminArtistSuggestionRequest, db: AsyncSession = Depends(get_db)
):
    await resolve_artist_suggestion(db, concert_id, body.artist_text, body.accept)
    await _mark_reviewed(db, concert_id)
    return await get_concert_detail(concert_id, db)


# 동명이인 오매칭(텍스트는 같은데 실존 인물이 다름, 예: LiSA→블랙핑크 Lisa) 강제 수정용 -
# 이름 재입력으로는 fuzzy/alias 매칭이 또 같은 틀린 canonical로 가버려서 admin이 검색으로
# 직접 고른 canonical_id로 통째로 재지정한다(reassign_artist_to_canonical 참고)
@router.post("/concerts/{concert_id}/artist-name/reassign", response_model=AdminConcertDetail)
async def reassign_artist_route(
    concert_id: UUID, body: AdminReassignArtistRequest, db: AsyncSession = Depends(get_db)
):
    await reassign_artist_to_canonical(db, concert_id, body.artist_text, body.canonical_id)
    await _mark_reviewed(db, concert_id)
    return await get_concert_detail(concert_id, db)


# 위 재지정은 "이미 존재하는" 다른 canonical을 검색해서 고르는 용도라, 검색해도 안 나오는
# (MusicBrainz/canonical_artists에 아예 없는 인디 등) 아티스트는 재지정할 대상이 없어 막혀있었음
# - 이 표기를 신규 canonical로 직접 등록한다(register_new_canonical_artist 참고)
@router.post("/concerts/{concert_id}/artist-name/register-new", response_model=AdminConcertDetail)
async def register_new_artist_route(
    concert_id: UUID,
    body: AdminRegisterNewArtistRequest,
    background_tasks: BackgroundTasks,
    db: AsyncSession = Depends(get_db),
):
    _, canonical = await register_new_canonical_artist(
        db, concert_id, body.artist_text, body.new_name, force_new=body.force_new
    )
    if canonical.mbid is None:
        # add_artist 라우트와 동일 - 응답 이후 백그라운드로 재조회(스로틀 때문에 여기서 기다리면 느려짐)
        background_tasks.add_task(try_link_canonical_to_musicbrainz, canonical.id)
    await _mark_reviewed(db, concert_id)
    return await get_concert_detail(concert_id, db)


@router.delete("/concerts/{concert_id}/artist-name", response_model=AdminConcertDetail)
async def delete_artist(
    concert_id: UUID,
    name: str = Query(...),
    blocklist: bool = Query(False),
    db: AsyncSession = Depends(get_db),
):
    await remove_artist_name(db, concert_id, name)
    if blocklist:
        # 배포 없이 즉시 반영 - DB 저장 + 이 프로세스의 인메모리 캐시 갱신까지 add_to_blocklist가 처리
        await add_to_blocklist(db, name)
    await _mark_reviewed(db, concert_id)
    return await get_concert_detail(concert_id, db)


# 아티스트를 수정할 필요 없이 봤을 때 이미 맞는 경우를 위한 명시적 검수 버튼용
@router.post("/concerts/{concert_id}/review", response_model=AdminConcertDetail)
async def mark_concert_reviewed(concert_id: UUID, db: AsyncSession = Depends(get_db)):
    await _mark_reviewed(db, concert_id)
    return await get_concert_detail(concert_id, db)


# "실제로는 페스티벌인데 event_type이 아니라서 크롤링/포스터 파이프라인 어느 쪽 자동 대상도
# 아닌" 공연을 admin이 발견했을 때 쓰는 버튼용 - event_type만 바꿔서 이후 라인업 재확인
# 배치(24시간마다) 대상에 편입시킨다. LLM 전송 타이밍은 자정 배치로 고정해두고 싶다는 요청이라
# 여기서 즉시 보내지 않음. 아티스트가 아직 안 채워진 상태이므로 검수 완료로도 취급하면 안 됨
# (_mark_reviewed 호출 안 함)
async def _mark_festival(db: AsyncSession, concert_id: UUID) -> None:
    concert = await db.get(Concert, concert_id)
    if concert is None:
        raise HTTPException(status_code=404, detail="공연 정보를 찾을 수 없습니다.")
    concert.event_type = EventType.FESTIVAL.value
    await db.commit()


@router.post("/concerts/{concert_id}/mark-festival", response_model=AdminConcertDetail)
async def mark_festival_route(concert_id: UUID, db: AsyncSession = Depends(get_db)):
    await _mark_festival(db, concert_id)
    return await get_concert_detail(concert_id, db)


@router.get("/canonical-artist", response_model=AdminCanonicalNameOptions)
async def get_canonical_artist_name_options(name: str = Query(...), db: AsyncSession = Depends(get_db)):
    result = await get_canonical_name_options(db, name)
    if result is None:
        raise HTTPException(status_code=404, detail="아직 매칭되지 않은 아티스트입니다.")
    canonical, options = result
    return AdminCanonicalNameOptions(
        canonical_id=canonical.id,
        canonical_name=canonical.canonical_name,
        display_name=canonical.display_name,
        current=canonical.display_name or canonical.canonical_name,
        mbid=canonical.mbid,
        options=options,
    )


@router.patch("/canonical-artist/{canonical_id}/display-name", response_model=AdminCanonicalNameOptions)
async def patch_canonical_artist_display_name(
    canonical_id: UUID, body: AdminDisplayNameRequest, db: AsyncSession = Depends(get_db)
):
    canonical = await set_display_name(db, canonical_id, body.display_name)
    _, options = await get_canonical_name_options(db, canonical.display_name)
    return AdminCanonicalNameOptions(
        canonical_id=canonical.id,
        canonical_name=canonical.canonical_name,
        display_name=canonical.display_name,
        current=canonical.display_name or canonical.canonical_name,
        mbid=canonical.mbid,
        options=options,
    )


# concerts.artist_name 배열 안에 names 중 아무거나 리터럴로 등장하는 공연들 - 아티스트 상세
# 화면의 "출연 공연"/"소속 그룹 공연" 목록 조회에 공용으로 씀
async def _concerts_matching_names(
    db: AsyncSession, names: set[str], limit: int = 50
) -> list[AdminArtistConcertItem]:
    if not names:
        return []
    name_unnested = (
        select(Concert.id.label("concert_id"), func.unnest(Concert.artist_name).label("name"))
        .where(Concert.artist_name != [])
        .subquery()
    )
    result = await db.execute(
        select(Concert)
        .join(name_unnested, name_unnested.c.concert_id == Concert.id)
        .where(name_unnested.c.name.in_(names))
        .order_by(Concert.start_date.desc())
        .distinct()
        .limit(limit)
    )
    return [
        AdminArtistConcertItem(id=c.id, name=c.name, poster_url=c.poster_url, start_date=c.start_date)
        for c in result.scalars().all()
    ]


# concerts.artist_name에 canonical_name이나 별칭 어느 쪽으로든 등장하는 canonical_id 전체 집합 -
# "아무 공연에도 안 나온(미출연) 아티스트" 배지/필터에 공용으로 씀. 페이지네이션과 무관하게 한 번만 계산
async def _used_canonical_ids(db: AsyncSession) -> set[UUID]:
    name_unnested = (
        select(func.unnest(Concert.artist_name).label("nm")).where(Concert.artist_name != []).subquery()
    )
    via_canonical = select(CanonicalArtist.id).join(
        name_unnested, CanonicalArtist.canonical_name == name_unnested.c.nm
    )
    via_alias = select(ArtistAlias.canonical_artist_id).join(
        name_unnested, ArtistAlias.alias_text == name_unnested.c.nm
    )
    rows = await db.execute(via_canonical.union(via_alias))
    return set(rows.scalars().all())


@router.get("/artists", response_model=AdminArtistListResponse)
async def list_artists(
    search: str | None = Query(None),
    unused_only: bool = Query(False),
    page: int = Query(1, ge=1),
    page_size: int = Query(_DEFAULT_PAGE_SIZE, ge=1, le=100),
    db: AsyncSession = Depends(get_db),
):
    used_ids = await _used_canonical_ids(db)

    query = select(CanonicalArtist)
    if search:
        like = f"%{search}%"
        alias_match_ids = select(ArtistAlias.canonical_artist_id).where(ArtistAlias.alias_text.ilike(like))
        query = query.where(
            or_(
                CanonicalArtist.canonical_name.ilike(like),
                CanonicalArtist.display_name.ilike(like),
                CanonicalArtist.id.in_(alias_match_ids),
            )
        )
    if unused_only:
        query = query.where(CanonicalArtist.id.not_in(used_ids)) if used_ids else query

    total = (await db.execute(select(func.count()).select_from(query.subquery()))).scalar_one()
    query = query.order_by(CanonicalArtist.canonical_name).offset((page - 1) * page_size).limit(page_size)
    artists = (await db.execute(query)).scalars().all()

    artist_ids = [a.id for a in artists]
    alias_counts: dict[UUID, int] = {}
    group_ids_present: set[UUID] = set()
    member_of_counts: dict[UUID, int] = {}
    if artist_ids:
        alias_rows = await db.execute(
            select(ArtistAlias.canonical_artist_id, func.count())
            .where(ArtistAlias.canonical_artist_id.in_(artist_ids))
            .group_by(ArtistAlias.canonical_artist_id)
        )
        alias_counts = dict(alias_rows.all())

        group_rows = await db.execute(
            select(ArtistGroupMembership.group_canonical_id.distinct()).where(
                ArtistGroupMembership.group_canonical_id.in_(artist_ids),
                ArtistGroupMembership.is_current.is_(True),
            )
        )
        group_ids_present = set(group_rows.scalars().all())

        member_rows = await db.execute(
            select(ArtistGroupMembership.member_canonical_id, func.count())
            .where(
                ArtistGroupMembership.member_canonical_id.in_(artist_ids),
                ArtistGroupMembership.is_current.is_(True),
            )
            .group_by(ArtistGroupMembership.member_canonical_id)
        )
        member_of_counts = dict(member_rows.all())

    items = [
        AdminArtistListItem(
            id=a.id,
            canonical_name=a.canonical_name,
            display_name=a.display_name,
            mbid=a.mbid,
            alias_count=alias_counts.get(a.id, 0),
            is_group=a.id in group_ids_present,
            member_of_count=member_of_counts.get(a.id, 0),
            is_unused=a.id not in used_ids,
        )
        for a in artists
    ]
    return AdminArtistListResponse(items=items, total=total, page=page, page_size=page_size)


@router.get("/artists/{canonical_id}", response_model=AdminArtistDetail)
async def get_artist_detail(canonical_id: UUID, db: AsyncSession = Depends(get_db)):
    canonical = await db.get(CanonicalArtist, canonical_id)
    if canonical is None:
        raise HTTPException(status_code=404, detail="아티스트를 찾을 수 없습니다.")

    alias_rows = (
        await db.execute(
            select(ArtistAlias).where(ArtistAlias.canonical_artist_id == canonical_id).order_by(ArtistAlias.alias_text)
        )
    ).scalars().all()

    # 이 아티스트가 그룹이면 현재 멤버, 멤버면 소속 그룹 - 양방향 다 보여줌. id를 같이 내려줘야
    # 프론트가 이름 재검색 없이 바로 삭제 API(remove_group_relation)를 호출할 수 있음
    group_members = sorted(
        (
            await db.execute(
                select(CanonicalArtist.id, CanonicalArtist.canonical_name)
                .join(ArtistGroupMembership, ArtistGroupMembership.member_canonical_id == CanonicalArtist.id)
                .where(
                    ArtistGroupMembership.group_canonical_id == canonical_id,
                    ArtistGroupMembership.is_current.is_(True),
                )
            )
        ).all(),
        key=lambda row: row.canonical_name,
    )
    member_of = sorted(
        (
            await db.execute(
                select(CanonicalArtist.id, CanonicalArtist.canonical_name)
                .join(ArtistGroupMembership, ArtistGroupMembership.group_canonical_id == CanonicalArtist.id)
                .where(
                    ArtistGroupMembership.member_canonical_id == canonical_id,
                    ArtistGroupMembership.is_current.is_(True),
                )
            )
        ).all(),
        key=lambda row: row.canonical_name,
    )

    own_names = {canonical.canonical_name} | {r.alias_text for r in alias_rows}
    concerts = await _concerts_matching_names(db, own_names)
    group_concerts = (
        await _concerts_matching_names(db, {row.canonical_name for row in member_of}) if member_of else []
    )

    return AdminArtistDetail(
        id=canonical.id,
        canonical_name=canonical.canonical_name,
        display_name=canonical.display_name,
        mbid=canonical.mbid,
        profile_image_url=canonical.profile_image_url,
        aliases=[{"id": r.id, "text": r.alias_text, "source": r.source} for r in alias_rows],
        group_members=[{"id": row.id, "name": row.canonical_name} for row in group_members],
        member_of=[{"id": row.id, "name": row.canonical_name} for row in member_of],
        concerts=concerts,
        group_concerts=group_concerts,
    )


@router.post("/artists/{canonical_id}/alias", response_model=AdminArtistDetail)
async def add_artist_alias_route(
    canonical_id: UUID, body: AdminAddAliasRequest, db: AsyncSession = Depends(get_db)
):
    await add_artist_alias(db, canonical_id, body.alias_text)
    return await get_artist_detail(canonical_id, db)


@router.delete("/artists/{canonical_id}/alias/{alias_id}", response_model=AdminArtistDetail)
async def remove_artist_alias_route(
    canonical_id: UUID, alias_id: UUID, db: AsyncSession = Depends(get_db)
):
    await remove_artist_alias(db, canonical_id, alias_id)
    return await get_artist_detail(canonical_id, db)


@router.post("/artists/{canonical_id}/group-relation", response_model=AdminArtistDetail)
async def add_group_relation_route(
    canonical_id: UUID, body: AdminGroupRelationAddRequest, db: AsyncSession = Depends(get_db)
):
    if body.role not in ("member", "group"):
        raise HTTPException(status_code=400, detail="role은 member 또는 group이어야 합니다.")
    await add_group_relation(db, canonical_id, body.other_name, body.role)
    return await get_artist_detail(canonical_id, db)


@router.delete("/artists/{canonical_id}/group-relation/{other_id}", response_model=AdminArtistDetail)
async def remove_group_relation_route(
    canonical_id: UUID, other_id: UUID, db: AsyncSession = Depends(get_db)
):
    await remove_group_relation(db, canonical_id, other_id)
    return await get_artist_detail(canonical_id, db)


# canonical을 DB에서 완전히 삭제(공연에서 이름만 지우는 /concerts/{id}/artist-name DELETE와는
# 다름) - 아직 공연에 등장하면 delete_canonical_artist가 거절
@router.delete("/artists/{canonical_id}")
async def delete_artist_route(canonical_id: UUID, db: AsyncSession = Depends(get_db)):
    await delete_canonical_artist(db, canonical_id)
    return {"deleted": True}


# 인터파크 링크가 없어서 자동 크롤링으로는 못 뽑는 공연(YES24/MELON만 있음) 목록 - 로컬
# 스크립트(scripts/yes24_melon_local_crawl.py)가 이 목록을 받아 각자 네트워크로 직접
# 크롤링하고, 결과는 아래 업로드 엔드포인트로 되돌려줌(get_yes24_melon_crawl_targets 참고)
@router.get("/crawl-targets/yes24-melon", response_model=AdminCrawlTargetsResponse)
async def list_yes24_melon_crawl_targets(db: AsyncSession = Depends(get_db)):
    concerts = await get_yes24_melon_crawl_targets(db)
    items = []
    for concert in concerts:
        links = concert.ticketing_links or {}
        candidates = [
            AdminCrawlTargetCandidate(site=site, url=links[site])
            for site in ("YES24", "MELON", "MELONTICKET")
            if site in links
        ]
        if not candidates:
            continue
        items.append(
            AdminCrawlTargetItem(
                concert_id=concert.id, kopis_id=concert.kopis_id, name=concert.name, candidates=candidates
            )
        )
    return AdminCrawlTargetsResponse(items=items)


# 로컬 스크립트가 직접 크롤링한 스크린샷을 업로드 - crawl_and_save가 성공했을 때와 동일한
# 상태(crawl_screenshot_url 갱신)로 맞춰준다. 전체 페이지 PNG라 일반 이미지 업로드
# (upload.py)보다 큰 상한을 둠 - 실측으로 20MB 넘는 페이지(이미지/공지사항 많은 상세페이지)가
# 나와서 60MB로 완화함
_MAX_CRAWL_SCREENSHOT_SIZE = 60 * 1024 * 1024  # 60MB


@router.post("/crawl-targets/{concert_id}/screenshot", response_model=AdminCrawlScreenshotUploadResponse)
async def upload_manual_crawl_screenshot(
    concert_id: UUID,
    request: Request,
    site: str = Query(..., description="YES24 또는 MELON - 로컬에서 실제로 성공한 사이트"),
    image: UploadFile = File(...),
    db: AsyncSession = Depends(get_db),
):
    content_length = request.headers.get("content-length")
    if content_length and int(content_length) > _MAX_CRAWL_SCREENSHOT_SIZE:
        raise HTTPException(status_code=413, detail="스크린샷 크기는 60MB를 초과할 수 없습니다.")

    image_bytes = await image.read(_MAX_CRAWL_SCREENSHOT_SIZE + 1)
    if len(image_bytes) > _MAX_CRAWL_SCREENSHOT_SIZE:
        raise HTTPException(status_code=413, detail="스크린샷 크기는 60MB를 초과할 수 없습니다.")

    concert = await save_manual_crawl_screenshot(db, concert_id, site, image_bytes)
    return AdminCrawlScreenshotUploadResponse(concert_id=concert.id, crawl_screenshot_url=concert.crawl_screenshot_url)


_PAGE_PATH = Path(__file__).resolve().parents[4] / "static" / "admin.html"
_ARTISTS_PAGE_PATH = Path(__file__).resolve().parents[4] / "static" / "admin_artists.html"


# 관리자 페이지 HTML(인증 없이 서빙 - 실서비스에선 Nginx Basic Auth로 서브도메인 자체를 막고,
# 화면 안의 API 호출은 verify_admin_key로 별도 보호됨). 별도 APIRouter로 분리해서 위
# verify_admin_key 의존성이 페이지 자체엔 안 걸리게 함
page_router = APIRouter()


@page_router.get("/", response_class=HTMLResponse, include_in_schema=False)
async def admin_page():
    return _PAGE_PATH.read_text(encoding="utf-8")


@page_router.get("/artists", response_class=HTMLResponse, include_in_schema=False)
async def admin_artists_page():
    return _ARTISTS_PAGE_PATH.read_text(encoding="utf-8")
