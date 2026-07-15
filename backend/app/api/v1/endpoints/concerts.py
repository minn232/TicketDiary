from datetime import date, timedelta

from fastapi import APIRouter, Depends, Query, Request, UploadFile, File, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.concert import Concert
from app.models.user import User
from app.schemas.concert import ConcertResponse, TicketScanExtracted, TicketScanResponse
from app.services.kopis import (
    search_concerts as kopis_search,
    search_concerts_multi as kopis_search_multi,
    search_concerts_by_venue as kopis_search_by_venue,
    get_concert_detail,
)
from app.services.ocr import extract_ticket_info

router = APIRouter()

_MAX_IMAGE_SIZE = 10 * 1024 * 1024  # 10MB


# 티켓 사진 스캔 -> OCR 추출 + KOPIS 후보 검색
@router.post("/scan", response_model=TicketScanResponse)
async def scan_ticket(
    request: Request,
    image: UploadFile = File(...),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    # Content-Length 헤더로 다운로드 전 사전 거절
    content_length = request.headers.get("content-length")
    if content_length and int(content_length) > _MAX_IMAGE_SIZE:
        raise HTTPException(status_code=413, detail="이미지 크기는 10MB를 초과할 수 없습니다.")

    # 최대 10MB+1 바이트만 읽어 초과 여부 판단
    image_bytes = await image.read(_MAX_IMAGE_SIZE + 1)
    if len(image_bytes) > _MAX_IMAGE_SIZE:
        raise HTTPException(status_code=413, detail="이미지 크기는 10MB를 초과할 수 없습니다.")

    # OCR + LLM으로 티켓 정보 추출
    extracted_raw = await extract_ticket_info(image_bytes, image.content_type or "image/jpeg")
    extracted = TicketScanExtracted(
        title=extracted_raw.get("title"),
        date=extracted_raw.get("date"),
        time=extracted_raw.get("time"),
        location=extracted_raw.get("location"),
        seat=extracted_raw.get("seat"),
        platform=extracted_raw.get("platform"),
        price=extracted_raw.get("price"),
        shipping_date=extracted_raw.get("shipping_date"),
        event_type=extracted_raw.get("event_type"),
    )

    # 공연명 + 공연일 기준으로 KOPIS 후보 검색
    # title 하나만으로 실패하면 원본 텍스트의 다른 후보 줄들로 순서대로 재시도
    # (예: "빨래는 오늘을 살아가는"으로 실패 -> 원본 텍스트 뒷줄의 "빨래"로 재시도)
    candidates = []
    title_candidates = extracted_raw.get("title_candidates") or (
        [extracted.title] if extracted.title else []
    )
    if title_candidates:
        start_date = None
        end_date = None
        if extracted.date:
            try:
                event_date = date.fromisoformat(extracted.date)
                start_date = event_date - timedelta(days=7)
                end_date = event_date + timedelta(days=7)
            except ValueError:
                pass
        try:
            candidates = await kopis_search_multi(
                db, title_candidates, start_date, end_date, extracted.location
            )
        except HTTPException:
            pass

    return TicketScanResponse(extracted=extracted, candidates=candidates)


# KOPIS 공연 검색 (keyword, start_date, end_date -> DB upsert)
@router.get("/search", response_model=list[ConcertResponse])
async def search_concerts(
    keyword: str = Query(...),
    start_date: date | None = Query(None),
    end_date: date | None = Query(None),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await kopis_search(db, keyword, start_date, end_date)


# 공연장 + 날짜 기준 KOPIS 재검색 (/scan 후보 목록에 원하는 공연이 없을 때 사용)
# 공연장+날짜 조합은 보통 1~2건으로 좁혀지는 강한 필터라 제목 표기가 KOPIS 등록명과 완전히 달라도 찾을 수 있음
@router.get("/search-by-venue", response_model=list[ConcertResponse])
async def search_concerts_by_venue(
    venue: str = Query(...),
    start_date: date | None = Query(None),
    end_date: date | None = Query(None),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await kopis_search_by_venue(db, venue, start_date, end_date)


# 공연 상세 조회 (DB -> KOPIS API + DB upsert)
@router.get("/{kopis_id}", response_model=ConcertResponse)
async def get_concert(
    kopis_id: str,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    # DB 조회
    result = await db.execute(select(Concert).where(Concert.kopis_id == kopis_id))
    concert = result.scalar_one_or_none()

    if concert is not None:
        return concert

    # KOPIS API
    return await get_concert_detail(db, kopis_id)
