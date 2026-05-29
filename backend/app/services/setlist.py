import json
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


# DB에서 real setlist 조회
async def get_real_setlist(db: AsyncSession, concert_id: UUID) -> RealSetlist:
    result = await db.execute(select(RealSetlist).where(RealSetlist.concert_id == concert_id))
    real_setlist = result.scalar_one_or_none()
    if real_setlist is None:
        raise HTTPException(status_code=404, detail="셋리스트를 찾을 수 없습니다.")
    return real_setlist


# concert의 아티스트, 공연일 기반 Setlist.fm 검색 -> 후보 목록 반환
async def search_setlists_for_concert(db: AsyncSession, concert_id: UUID) -> list[dict]:
    concert = await _get_concert(db, concert_id)

    if not concert.artist_name:
        raise HTTPException(status_code=400, detail="공연에 아티스트 정보가 없습니다.")

    return await search_setlists(concert.artist_name[0], concert.start_date.date())


# 유저가 직접 곡 목록 수정
async def update_real_setlist(
    db: AsyncSession, concert_id: UUID, songs: list[SongEntry], nickname: str | None
) -> RealSetlist:
    result = await db.execute(select(RealSetlist).where(RealSetlist.concert_id == concert_id))
    real_setlist = result.scalar_one_or_none()
    if real_setlist is None:
        raise HTTPException(status_code=404, detail="셋리스트를 찾을 수 없습니다.")

    real_setlist.songs = json.dumps([s.model_dump() for s in songs], ensure_ascii=False)
    real_setlist.is_user_edited = True
    real_setlist.edited_user_nickname = nickname or "익명"

    await db.commit()
    await db.refresh(real_setlist)
    return real_setlist


# setlistfm_id로 셋리스트 가져와 DB upsert
async def fetch_and_save_real_setlist(
    db: AsyncSession, concert_id: UUID, setlistfm_id: str
) -> RealSetlist:
    await _get_concert(db, concert_id)

    # Setlist.fm에서 가져와 곡 목록 파싱
    setlist_data = await get_setlist_by_id(setlistfm_id)
    songs = extract_songs(setlist_data)
    songs_json = json.dumps(songs, ensure_ascii=False)

    # DB upsert
    result = await db.execute(select(RealSetlist).where(RealSetlist.concert_id == concert_id))
    real_setlist = result.scalar_one_or_none()

    if real_setlist is None:
        real_setlist = RealSetlist(
            concert_id=concert_id,
            setlistfm_id=setlistfm_id,
            songs=songs_json,
        )
        db.add(real_setlist)
    else:
        # 기존 셋리스트 덮어씀 (유저 편집 이력 초기화)
        real_setlist.setlistfm_id = setlistfm_id
        real_setlist.songs = songs_json
        real_setlist.is_user_edited = False
        real_setlist.edited_user_nickname = None

    await db.commit()
    await db.refresh(real_setlist)
    return real_setlist
