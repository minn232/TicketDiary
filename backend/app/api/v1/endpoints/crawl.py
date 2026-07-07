import logging
from datetime import date, datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import verify_llm_api_key
from app.models.concert import Concert
from app.schemas.venue_layout import CrawlResultRequest, CrawlResultResponse
from app.services.notification import schedule_ticketing_day_notifications
from app.services.timetable import upsert_timetable
from app.services.venue_layout import upsert_venue_layout

logger = logging.getLogger(__name__)

router = APIRouter()


# LLM팀이 크롤링 분석 결과를 전송하는 웹훅 엔드포인트
@router.post("/{concert_id}/crawl-result", response_model=CrawlResultResponse)
async def receive_crawl_result(
    concert_id: UUID,
    body: CrawlResultRequest,
    db: AsyncSession = Depends(get_db),
    _: None = Depends(verify_llm_api_key),
):
    result = await db.execute(select(Concert).where(Concert.id == concert_id))
    concert = result.scalar_one_or_none()
    if concert is None:
        raise HTTPException(status_code=404, detail="공연 정보를 찾을 수 없습니다.")

    updated: list[str] = []

    if body.timetable is not None:
        await upsert_timetable(db, concert_id, body.timetable, commit=False)
        updated.append("timetable")

    if body.prices is not None:
        concert.price = body.prices
        updated.append("prices")

    if body.venue_layout is not None:
        await upsert_venue_layout(
            db,
            concert_id,
            image_url=body.venue_layout.image_url,
            layout_data=body.venue_layout.layout_data,
            commit=False,
        )
        updated.append("venue_layout")

    if body.ticketing_date is not None:
        try:
            td = date.fromisoformat(body.ticketing_date)
            concert.ticketing_date = datetime(td.year, td.month, td.day, tzinfo=timezone.utc)
            updated.append("ticketing_date")
        except ValueError:
            logger.warning(f"잘못된 ticketing_date 형식: {body.ticketing_date}")

    if updated:
        await db.commit()

    # 티켓팅 날 알림은 commit 확정 후 처리 (중복 방지 + 유저 조회 포함)
    if "ticketing_date" in updated:
        await schedule_ticketing_day_notifications(db, concert_id)

    logger.info(f"크롤링 결과 수신 concert_id={concert_id} updated={updated}")
    return CrawlResultResponse(updated=updated)
