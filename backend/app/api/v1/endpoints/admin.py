from pathlib import Path
from uuid import UUID

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query
from fastapi.responses import HTMLResponse
from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import verify_admin_key
from app.models.artist_normalization import ArtistNormalizationStatus
from app.models.concert import Concert
from app.schemas.admin import (
    AdminArtistAddRequest,
    AdminArtistRenameRequest,
    AdminCanonicalNameOptions,
    AdminConcertDetail,
    AdminConcertListItem,
    AdminConcertListResponse,
    AdminDisplayNameRequest,
)
from app.services.artist_blocklist import add_to_blocklist
from app.services.artist_normalization import (
    add_artist_name,
    confirm_artist_name_change,
    get_canonical_name_options,
    remove_artist_name,
    set_display_name,
    try_link_canonical_to_musicbrainz,
)

router = APIRouter(dependencies=[Depends(verify_admin_key)])

_DEFAULT_PAGE_SIZE = 20


# 콘서트명/kopis_id/아티스트명 어디든 걸리는 느슨한 검색 - artist_name이 배열이라 콤마로
# 이어붙인 문자열로 만들어 통째로 ILIKE (정확한 아티스트 단위 검색이 아니라 훑어보기용)
def _search_filter(keyword: str):
    like = f"%{keyword}%"
    joined_artists = func.array_to_string(Concert.artist_name, ",")
    return or_(Concert.name.ilike(like), Concert.kopis_id.ilike(like), joined_artists.ilike(like))


@router.get("/concerts", response_model=AdminConcertListResponse)
async def list_concerts(
    search: str | None = Query(None),
    flagged_only: bool = Query(False),
    page: int = Query(1, ge=1),
    page_size: int = Query(_DEFAULT_PAGE_SIZE, ge=1, le=100),
    db: AsyncSession = Depends(get_db),
):
    flagged_concert_ids = select(ArtistNormalizationStatus.concert_id).where(
        ArtistNormalizationStatus.status.in_(["unconfirmed", "ambiguous"])
    )

    query = select(Concert)
    if search:
        query = query.where(_search_filter(search))
    if flagged_only:
        query = query.where(Concert.id.in_(flagged_concert_ids))

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
                ArtistNormalizationStatus.status.in_(["unconfirmed", "ambiguous"]),
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

    return AdminConcertDetail(
        id=concert.id,
        kopis_id=concert.kopis_id,
        name=concert.name,
        artist_name=concert.artist_name,
        poster_url=concert.poster_url,
        venue=concert.venue,
        start_date=concert.start_date,
        ticketing_links=concert.ticketing_links,
        statuses=[
            {"artist_text": r.artist_text, "status": r.status, "attempt_count": r.attempt_count}
            for r in status_rows
        ],
    )


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
    return await get_concert_detail(concert_id, db)


@router.patch("/concerts/{concert_id}/artist-name", response_model=AdminConcertDetail)
async def rename_artist(concert_id: UUID, body: AdminArtistRenameRequest, db: AsyncSession = Depends(get_db)):
    await confirm_artist_name_change(db, concert_id, body.original_name, body.confirmed_name)
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


_PAGE_PATH = Path(__file__).resolve().parents[4] / "static" / "admin.html"


# 관리자 페이지 HTML(인증 없이 서빙 - 실서비스에선 Nginx Basic Auth로 서브도메인 자체를 막고,
# 화면 안의 API 호출은 verify_admin_key로 별도 보호됨). 별도 APIRouter로 분리해서 위
# verify_admin_key 의존성이 페이지 자체엔 안 걸리게 함
page_router = APIRouter()


@page_router.get("/", response_class=HTMLResponse, include_in_schema=False)
async def admin_page():
    return _PAGE_PATH.read_text(encoding="utf-8")
