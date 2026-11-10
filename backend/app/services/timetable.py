from uuid import UUID

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.concert import Concert
from app.models.timetable import TimeTable


# 타임테이블 조회
async def get_timetable(db: AsyncSession, concert_id: UUID) -> TimeTable:
    result = await db.execute(select(TimeTable).where(TimeTable.concert_id == concert_id))
    timetable = result.scalar_one_or_none()
    if timetable is None:
        raise HTTPException(status_code=404, detail="타임테이블을 찾을 수 없습니다.")
    return timetable


async def get_timetable_or_none(db: AsyncSession, concert_id: UUID) -> TimeTable | None:
    result = await db.execute(select(TimeTable).where(TimeTable.concert_id == concert_id))
    return result.scalar_one_or_none()


# 타임테이블 upsert - admin_edited가 None이면 표시는 그대로 두고, True/False면 그 값으로 바꿈
async def upsert_timetable(
    db: AsyncSession,
    concert_id: UUID,
    contents: list[dict],
    commit: bool = True,
    admin_edited: bool | None = None,
) -> TimeTable:
    concert_result = await db.execute(select(Concert).where(Concert.id == concert_id))
    if concert_result.scalar_one_or_none() is None:
        raise HTTPException(status_code=404, detail="공연 정보를 찾을 수 없습니다.")

    result = await db.execute(select(TimeTable).where(TimeTable.concert_id == concert_id))
    timetable = result.scalar_one_or_none()

    if timetable is None:
        timetable = TimeTable(concert_id=concert_id, contents=contents, admin_edited=bool(admin_edited))
        db.add(timetable)
    else:
        timetable.contents = contents
        if admin_edited is not None:
            timetable.admin_edited = admin_edited

    if commit:
        await db.commit()
        await db.refresh(timetable)
    return timetable


# 관리자 직접 편집 표시만 끄기 - 시간표 내용은 그대로 두고 다음 LLM 콜백부터 다시 받게 함
async def release_timetable_admin_edit(db: AsyncSession, concert_id: UUID) -> None:
    timetable = await get_timetable_or_none(db, concert_id)
    if timetable is not None and timetable.admin_edited:
        timetable.admin_edited = False
        await db.commit()
