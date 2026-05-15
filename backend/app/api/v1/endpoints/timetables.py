from uuid import UUID
from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession
from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.user import User
from app.schemas.timetable import TimeTableUpdate, TimeTableResponse
from app.services.timetable import get_timetable, upsert_timetable

router = APIRouter()


# 타임테이블 조회
@router.get("/{concert_id}/timetable", response_model=TimeTableResponse)
async def get_timetable_endpoint(
    concert_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await get_timetable(db, concert_id)


# 타임테이블 upsert (OCR 결과 수신 및 저장)
@router.put("/{concert_id}/timetable", response_model=TimeTableResponse)
async def upsert_timetable_endpoint(
    concert_id: UUID,
    body: TimeTableUpdate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    contents = [entry.model_dump() for entry in body.contents]
    return await upsert_timetable(db, concert_id, contents)
