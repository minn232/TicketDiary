from datetime import date
from uuid import UUID

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.concert import Concert
from app.models.setlist import RealSetlist
from app.schemas.setlist import SongEntry
from app.services.setlistfm import search_setlists, get_setlist_by_id, extract_songs


# concert 조회 (없으면 404)
async def _get_concert(db: AsyncSession, concert_id: UUID) -> Concert:
    result = await db.execute(select(Concert).where(Concert.id == concert_id))
    concert = result.scalar_one_or_none()
    if concert is None:
        raise HTTPException(status_code=404, detail="공연 정보를 찾을 수 없습니다.")
    return concert


# 실제 셋리스트가 적용될 날짜를 결정. explicit_date가 오면 그대로 쓰고(티켓의 attended_date
# 등), 없으면 하루짜리 공연일 때만 concert.start_date로 자동 결정. 여러 날짜에 걸친 공연인데
# 날짜를 특정할 방법이 없으면(예: attended_date 없는 티켓) 400으로 명확히 안내 -
# concert_id 하나에 날짜 다른 셋리스트가 여러 개 있을 수 있어서 추측하면 안 됨
def resolve_performance_date(concert: Concert, explicit_date: date | None) -> date:
    if explicit_date is not None:
        return explicit_date
    if concert.start_date.date() == concert.end_date.date():
        return concert.start_date.date()
    raise HTTPException(status_code=400, detail="여러 날짜에 걸친 공연입니다. 날짜를 지정해주세요.")


# DB에서 real setlist 조회
async def get_real_setlist(
    db: AsyncSession, concert_id: UUID, explicit_date: date | None = None
) -> RealSetlist:
    concert = await _get_concert(db, concert_id)
    performance_date = resolve_performance_date(concert, explicit_date)

    result = await db.execute(
        select(RealSetlist).where(
            RealSetlist.concert_id == concert_id,
            RealSetlist.performance_date == performance_date,
        )
    )
    real_setlist = result.scalar_one_or_none()
    if real_setlist is None:
        raise HTTPException(status_code=404, detail="셋리스트를 찾을 수 없습니다.")
    return real_setlist


# concert의 아티스트, 공연일 기반 Setlist.fm 검색 -> 후보 목록 반환
async def search_setlists_for_concert(
    db: AsyncSession, concert_id: UUID, explicit_date: date | None = None
) -> list[dict]:
    concert = await _get_concert(db, concert_id)

    if not concert.artist_name:
        raise HTTPException(status_code=400, detail="공연에 아티스트 정보가 없습니다.")

    performance_date = resolve_performance_date(concert, explicit_date)
    return await search_setlists(concert.artist_name[0], performance_date)


# 유저가 직접 곡 목록 수정
async def update_real_setlist(
    db: AsyncSession,
    concert_id: UUID,
    songs: list[SongEntry],
    nickname: str | None,
    explicit_date: date | None = None,
) -> RealSetlist:
    concert = await _get_concert(db, concert_id)
    performance_date = resolve_performance_date(concert, explicit_date)

    result = await db.execute(
        select(RealSetlist).where(
            RealSetlist.concert_id == concert_id,
            RealSetlist.performance_date == performance_date,
        )
    )
    real_setlist = result.scalar_one_or_none()
    if real_setlist is None:
        raise HTTPException(status_code=404, detail="셋리스트를 찾을 수 없습니다.")

    real_setlist.songs = [s.model_dump() for s in songs]
    real_setlist.is_user_edited = True
    real_setlist.edited_user_nickname = nickname or "익명"

    await db.commit()
    await db.refresh(real_setlist)
    return real_setlist


# setlistfm_id로 셋리스트 가져와 DB upsert
async def fetch_and_save_real_setlist(
    db: AsyncSession,
    concert_id: UUID,
    setlistfm_id: str,
    explicit_date: date | None = None,
) -> RealSetlist:
    concert = await _get_concert(db, concert_id)
    performance_date = resolve_performance_date(concert, explicit_date)

    # Setlist.fm에서 가져와 곡 목록 파싱
    setlist_data = await get_setlist_by_id(setlistfm_id)
    songs = extract_songs(setlist_data)

    # DB upsert (concert_id + performance_date 조합 기준)
    result = await db.execute(
        select(RealSetlist).where(
            RealSetlist.concert_id == concert_id,
            RealSetlist.performance_date == performance_date,
        )
    )
    real_setlist = result.scalar_one_or_none()

    if real_setlist is None:
        real_setlist = RealSetlist(
            concert_id=concert_id,
            performance_date=performance_date,
            setlistfm_id=setlistfm_id,
            songs=songs,
        )
        db.add(real_setlist)
    else:
        # 기존 셋리스트 덮어씀 (유저 편집 이력 초기화)
        real_setlist.setlistfm_id = setlistfm_id
        real_setlist.songs = songs
        real_setlist.is_user_edited = False
        real_setlist.edited_user_nickname = None

    await db.commit()
    await db.refresh(real_setlist)
    return real_setlist
