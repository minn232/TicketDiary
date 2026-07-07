from uuid import UUID

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.user import User
from app.schemas.venue_layout import VenueLayoutResponse
from app.services.venue_layout import get_venue_layout

router = APIRouter()


# 좌석 배치 조회
@router.get("/{concert_id}/venue-layout", response_model=VenueLayoutResponse)
async def get_venue_layout_endpoint(
    concert_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await get_venue_layout(db, concert_id)
