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


# 타임테이블 upsert
async def upsert_timetable(
    db: AsyncSession, concert_id: UUID, contents: list[dict], commit: bool = True
) -> TimeTable:
    concert_result = await db.execute(select(Concert).where(Concert.id == concert_id))
    if concert_result.scalar_one_or_none() is None:
        raise HTTPException(status_code=404, detail="공연 정보를 찾을 수 없습니다.")

    result = await db.execute(select(TimeTable).where(TimeTable.concert_id == concert_id))
    timetable = result.scalar_one_or_none()

    if timetable is None:
        timetable = TimeTable(concert_id=concert_id, contents=contents)
        db.add(timetable)
    else:
        timetable.contents = contents

    if commit:
        await db.commit()
        await db.refresh(timetable)
    return timetable
