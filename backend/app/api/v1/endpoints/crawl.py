import logging
from datetime import date, datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import verify_llm_api_key
from app.models.concert import Concert
from app.schemas.artist_extraction import ArtistExtractionResult, ArtistExtractionResponse
from app.schemas.venue_layout import CrawlResultRequest, CrawlResultResponse
from app.services.artist_matching import get_known_artist_names, normalize_artist_names
from app.services.kopis import _create_news_feeds_for_concert
from app.services.notification import schedule_ticketing_day_notifications
from app.services.ticket import (
    backfill_delivery_date_from_concert,
    backfill_first_last_day_from_concert,
    upgrade_event_type_if_multi_artist,
)
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
        contents = [entry.model_dump() for entry in body.timetable]
        await upsert_timetable(db, concert_id, contents, commit=False)
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

    delivery_date: datetime | None = None
    if body.delivery_date is not None:
        try:
            dd = date.fromisoformat(body.delivery_date)
            delivery_date = datetime(dd.year, dd.month, dd.day, tzinfo=timezone.utc)
            concert.delivery_date = delivery_date
            updated.append("delivery_date")
        except ValueError:
            logger.warning(f"잘못된 delivery_date 형식: {body.delivery_date}")

    # 포스터 기반 추출(artist-result 웹훅)이 이미 성공했으면 크롤링 결과로 덮어쓰지 않음 -
    # 페스티벌처럼 포스터만으로는 실패하기 쉬운 경우의 대체 경로일 뿐, 우선순위를 갖진 않음
    upgraded_to_festival = False
    if body.artist_name and not concert.artist_name:
        known_artist_names = await get_known_artist_names(db)
        concert.artist_name = normalize_artist_names(body.artist_name, known_artist_names)
        updated.append("artist_name")
        upgraded_to_festival = upgrade_event_type_if_multi_artist(concert)

    if updated:
        await db.commit()

    # 티켓팅 날 알림은 commit 확정 후 처리 (중복 방지 + 유저 조회 포함)
    if "ticketing_date" in updated:
        await schedule_ticketing_day_notifications(db, concert_id)

    # 이미 등록된 티켓 중 자체 delivery_date가 없는 것들에 백필 + DELIVERY_DAY 알림 재스케줄
    if "delivery_date" in updated:
        await backfill_delivery_date_from_concert(db, concert_id, delivery_date)

    # 새로 채워진 아티스트가 이미 존재하는 팔로워와 매칭되면 뉴스피드 소급 생성 (artist-result 웹훅과 동일)
    if "artist_name" in updated:
        await db.refresh(concert)
        await _create_news_feeds_for_concert(db, concert)
        await db.commit()

    # event_type이 SOLO->FESTIVAL로 승격된 경우, 이미 등록된 티켓들의 첫콘/막콘 값 재계산
    if upgraded_to_festival:
        await backfill_first_last_day_from_concert(db, concert_id)

    logger.info(f"크롤링 결과 수신 concert_id={concert_id} updated={updated}")
    return CrawlResultResponse(updated=updated)


# LLM팀이 공연명+포스터 기반 아티스트 추출 결과를 전송하는 웹훅 엔드포인트
@router.post("/{concert_id}/artist-result", response_model=ArtistExtractionResponse)
async def receive_artist_extraction_result(
    concert_id: UUID,
    body: ArtistExtractionResult,
    db: AsyncSession = Depends(get_db),
    _: None = Depends(verify_llm_api_key),
):
    result = await db.execute(select(Concert).where(Concert.id == concert_id))
    concert = result.scalar_one_or_none()
    if concert is None:
        raise HTTPException(status_code=404, detail="공연 정보를 찾을 수 없습니다.")

    if body.artist_name:
        known_artist_names = await get_known_artist_names(db)
        concert.artist_name = normalize_artist_names(body.artist_name, known_artist_names)
        upgraded_to_festival = upgrade_event_type_if_multi_artist(concert)
        await db.commit()
        await db.refresh(concert)
        # 새로 채워진 아티스트가 이미 존재하는 팔로워와 매칭되면 뉴스피드 소급 생성
        await _create_news_feeds_for_concert(db, concert)
        await db.commit()
        # event_type이 SOLO->FESTIVAL로 승격된 경우, 이미 등록된 티켓들의 첫콘/막콘 값 재계산
        if upgraded_to_festival:
            await backfill_first_last_day_from_concert(db, concert_id)

    logger.info(f"아티스트 추출 결과 수신 concert_id={concert_id} artist_name={concert.artist_name}")
    return ArtistExtractionResponse(artist_name=concert.artist_name)
