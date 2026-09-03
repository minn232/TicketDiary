import logging
import re
from datetime import date, datetime, timezone
from uuid import UUID

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import verify_llm_api_key
from app.models.concert import Concert
from app.schemas.artist_extraction import ArtistExtractionResult, ArtistExtractionResponse
from app.schemas.venue_layout import CrawlResultRequest, CrawlResultResponse
from app.models.lineup import ConcertLineup
from app.services.artist_matching import get_known_artist_names, merge_artist_names
from app.services.artist_normalization import normalize_specific_artists, queue_for_normalization
from app.services.kopis import _create_news_feeds_for_concert
from app.services.lineup import upsert_concert_lineup
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

_WHITESPACE_RE = re.compile(r"\s+")


# seat_type 비교(중복 판단)용 정규화 - "R석"/"r석"/"R 석"처럼 대소문자·공백 표기만 다른 걸
# 별개 좌석으로 오인하지 않게 함. 실제 저장값은 원본 그대로 둔다(KOPIS 표기를 우선시하는 게
# 목적이라 이미 있는 값을 크롤링 쪽 표기로 바꿔치기하면 안 됨 - 비교에만 쓰고 버리는 값)
def _normalize_seat_type(seat_type: str) -> str:
    return _WHITESPACE_RE.sub("", seat_type).upper()


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

    # KOPIS가 이미 채워둔 가격(seat_type)은 우선순위를 두고 덮어쓰지 않는다 - KOPIS 값이 더
    # 신뢰할 수 있다고 보고, 크롤링 결과 중 KOPIS에 없는 seat_type(얼리버드/팬티켓 등 KOPIS
    # 안내에는 없는 추가 가격 유형)만 새로 추가한다. 같은 seat_type이 이미 있으면 크롤링 값은
    # 무시(KOPIS 값 유지) - 겹치는 걸 새로 덮어쓰고 싶으면 이 필터를 없애면 됨
    if body.prices is not None:
        existing_prices = concert.price or []
        existing_seat_types = {
            _normalize_seat_type(p["seat_type"])
            for p in existing_prices
            if isinstance(p, dict) and p.get("seat_type")
        }
        new_prices = [
            p
            for p in body.prices
            if p.get("seat_type") and _normalize_seat_type(p["seat_type"]) not in existing_seat_types
        ]
        if new_prices:
            concert.price = existing_prices + new_prices
            updated.append("prices")

    if body.food_allowed is not None:
        concert.food_allowed = body.food_allowed
        updated.append("food_allowed")

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

    # 선예매/1차/2차 등 단계별 전체 내역 - ticketing_date(가장 이른 날짜, 완료 판정용)와는
    # 별개로 화면 표시용 원본을 그대로 저장. 같은 크롤링 결과에서 같이 오므로 매번 통째로
    # 덮어써도 되고(병합할 과거 값이 따로 없음), date가 있는 항목만 형식 검증한다
    if body.ticketing_phases is not None:
        valid_phases = []
        for entry in body.ticketing_phases:
            if entry.date is not None:
                try:
                    date.fromisoformat(entry.date)
                except ValueError:
                    logger.warning(f"잘못된 ticketing_phases date 형식: {entry.date}")
                    continue
            valid_phases.append({"phase": entry.phase, "date": entry.date})
        if valid_phases:
            concert.ticketing_phases = valid_phases
            updated.append("ticketing_phases")

    delivery_date: datetime | None = None
    if body.delivery_date is not None:
        try:
            dd = date.fromisoformat(body.delivery_date)
            delivery_date = datetime(dd.year, dd.month, dd.day, tzinfo=timezone.utc)
            concert.delivery_date = delivery_date
            updated.append("delivery_date")
        except ValueError:
            logger.warning(f"잘못된 delivery_date 형식: {body.delivery_date}")

    # 크롤링 결과와 포스터 기반 추출(artist-result 웹훅) 양쪽에서 아티스트가 들어올 수 있고,
    # 페스티벌은 1차/2차/3차로 시간차를 두고 라인업이 늘어나므로 덮어쓰지 않고 합집합으로 병합
    upgraded_to_festival = False
    known_artist_names: set[str] | None = None
    if body.artist_name or body.lineup:
        known_artist_names = await get_known_artist_names(db)

    if body.artist_name:
        merged = merge_artist_names(concert.artist_name, body.artist_name, known_artist_names)
        if merged != (concert.artist_name or []):
            concert.artist_name = merged
            updated.append("artist_name")
            upgraded_to_festival = upgrade_event_type_if_multi_artist(concert)

    # 아티스트별 실제 출연일 upsert(union-only, 삭제 없음) - source="crawl"이 포스터 추출보다
    # 우선순위 높음(app/services/lineup.py). concert.artist_name(방금 병합된 값 포함)까지
    # known_names에 섞어서 표기를 최대한 맞춤
    if body.lineup:
        lineup_known_names = set(known_artist_names or set()) | set(concert.artist_name or [])
        entries = [e.model_dump() for e in body.lineup]
        lineup_changed = await upsert_concert_lineup(
            db, concert_id, entries, source="crawl", known_names=lineup_known_names, commit=False
        )
        if lineup_changed:
            updated.append("lineup")

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
    background_tasks: BackgroundTasks,
    db: AsyncSession = Depends(get_db),
    _: None = Depends(verify_llm_api_key),
):
    result = await db.execute(select(Concert).where(Concert.id == concert_id))
    concert = result.scalar_one_or_none()
    if concert is None:
        raise HTTPException(status_code=404, detail="공연 정보를 찾을 수 없습니다.")

    known_artist_names: set[str] | None = None
    if body.artist_name or body.lineup:
        known_artist_names = await get_known_artist_names(db)

    if body.artist_name:
        # 항상 합집합 병합 - 예전엔 소규모(4명 미만) 공연에서 KOPIS가 본명/멤버명을 주는 문제
        # (존박→박성규 등) 때문에 replace=True로 KOPIS 쪽을 통째로 버렸지만, LLM이 포스터에서
        # 일부 멤버를 놓치면 그만큼 라인업이 사라지는 부작용이 있었음. 이제 MusicBrainz alias
        # 매칭(services/artist_normalization.py)이 본명↔활동명을 배치로 자동 정리해주므로 그냥
        # 합집합으로 두고 정리는 정규화 배치에 맡김. merge_artist_names의 replace=True 자체는
        # 다른 상황에 필요할 수 있어 남겨둠(artist_matching.py)
        merged = merge_artist_names(concert.artist_name, body.artist_name, known_artist_names)
        if merged != (concert.artist_name or []):
            concert.artist_name = merged
            upgraded_to_festival = upgrade_event_type_if_multi_artist(concert, body.event_type)
            await db.commit()
            await db.refresh(concert)
            # 새로 채워진 아티스트가 이미 존재하는 팔로워와 매칭되면 뉴스피드 소급 생성
            await _create_news_feeds_for_concert(db, concert)
            await db.commit()
            # event_type이 SOLO->FESTIVAL로 승격된 경우, 이미 등록된 티켓들의 첫콘/막콘 값 재계산
            if upgraded_to_festival:
                await backfill_first_last_day_from_concert(db, concert_id)

    # 아티스트별 실제 출연일 upsert(union-only, 삭제 없음) - 크롤링 쪽(source="crawl")이 이미
    # 같은 (아티스트,날짜)를 확인해뒀으면 포스터 쪽(source="poster")은 그 row를 안 밀어냄
    # (app/services/lineup.py)
    if body.lineup:
        lineup_known_names = set(known_artist_names or set()) | set(concert.artist_name or [])
        entries = [e.model_dump() for e in body.lineup]
        await upsert_concert_lineup(db, concert_id, entries, source="poster", known_names=lineup_known_names)

    # MusicBrainz 정규화 큐잉 - pending row만 적립하고 끝(외부 호출 없음, 콜백 타임아웃과 무관).
    # 실제 조회/치환은 별도 배치(services/artist_normalization.py)가 수행. concert.artist_name뿐
    # 아니라 방금 upsert된 concert_lineups 표기도 같이 큐잉해 둘이 어긋나는 경우를 놓치지 않음
    queue_names = set(concert.artist_name or [])
    if body.lineup:
        lineup_result = await db.execute(
            select(ConcertLineup.artist).where(ConcertLineup.concert_id == concert_id)
        )
        queue_names |= set(lineup_result.scalars().all())
    if queue_names:
        await queue_for_normalization(db, concert_id, list(queue_names))
        # 다음날 밤 정기 배치를 기다리지 않고 바로 시도 - 응답 이후 백그라운드로 실행되므로
        # 웹훅 응답 시간엔 영향 없음(services/artist_normalization.py의 normalize_specific_artists 참고)
        background_tasks.add_task(normalize_specific_artists, concert_id, list(queue_names))

    logger.info(f"아티스트 추출 결과 수신 concert_id={concert_id} artist_name={concert.artist_name}")
    return ArtistExtractionResponse(artist_name=concert.artist_name)
