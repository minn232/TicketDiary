from uuid import UUID

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.concert import Concert
from app.models.venue_layout import VenueLayout


async def get_venue_layout(db: AsyncSession, concert_id: UUID) -> VenueLayout:
    result = await db.execute(select(VenueLayout).where(VenueLayout.concert_id == concert_id))
    venue_layout = result.scalar_one_or_none()
    if venue_layout is None:
        raise HTTPException(status_code=404, detail="좌석 배치 정보를 찾을 수 없습니다.")
    return venue_layout


async def upsert_venue_layout(
    db: AsyncSession,
    concert_id: UUID,
    image_url: str | None,
    layout_data: dict | None,
    commit: bool = True,
) -> VenueLayout:
    concert_result = await db.execute(select(Concert).where(Concert.id == concert_id))
    if concert_result.scalar_one_or_none() is None:
        raise HTTPException(status_code=404, detail="공연 정보를 찾을 수 없습니다.")

    result = await db.execute(select(VenueLayout).where(VenueLayout.concert_id == concert_id))
    venue_layout = result.scalar_one_or_none()

    if venue_layout is None:
        venue_layout = VenueLayout(concert_id=concert_id, image_url=image_url, layout_data=layout_data)
        db.add(venue_layout)
    else:
        if image_url is not None:
            venue_layout.image_url = image_url
        if layout_data is not None:
            venue_layout.layout_data = layout_data

    if commit:
        await db.commit()
        await db.refresh(venue_layout)
    return venue_layout
