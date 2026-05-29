from typing import Literal

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.user import User
from app.schemas.summary import SummaryResponse
from app.services.summary import get_summary

router = APIRouter()


# 기간별 결산 조회 (6m / 1y / all)
@router.get("", response_model=SummaryResponse)
async def summary(
    period: Literal["6m", "1y", "all"] = Query("all"),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await get_summary(db, current_user.id, period)
