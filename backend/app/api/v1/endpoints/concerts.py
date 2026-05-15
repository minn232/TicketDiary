from fastapi import APIRouter, Depends, Query, UploadFile, File, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from datetime import date, timedelta
from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.concert import Concert
from app.models.user import User
from app.schemas.concert import ConcertResponse, TicketScanExtracted, TicketScanResponse
from app.services.kopis import search_concerts as kopis_search, get_concert_detail
from app.services.ocr import extract_ticket_info

router = APIRouter()

_MAX_IMAGE_SIZE = 10 * 1024 * 1024  # 10MB


# 티켓 사진 스캔 -> OCR 추출 + KOPIS 후보 검색
@router.post("/scan", response_model=TicketScanResponse)
async def scan_ticket(
    image: UploadFile = File(...),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    image_bytes = await image.read()
    if len(image_bytes) > _MAX_IMAGE_SIZE:
        raise HTTPException(status_code=413, detail="이미지 크기는 10MB를 초과할 수 없습니다.")

    # OCR로 티켓 정보 추출
    extracted_raw = await extract_ticket_info(image_bytes, image.content_type or "image/jpeg")
    extracted = TicketScanExtracted(
        artist_name=extracted_raw.get("artist_name"),
        venue=extracted_raw.get("venue"),
        event_date=extracted_raw.get("event_date"),
    )

    # 추출된 정보 기반으로 KOPIS에서 공연 후보 검색 (아티스트명 기준, 공연일 ±7일)
    candidates = []
    if extracted.artist_name:
        start_date = None
        end_date = None
        if extracted.event_date:
            try:
                event_date = date.fromisoformat(extracted.event_date)
                start_date = event_date - timedelta(days=7)
                end_date = event_date + timedelta(days=7)
            except ValueError:
                pass
        try:
            candidates = await kopis_search(db, extracted.artist_name, start_date, end_date)
        except HTTPException:
            pass

    return TicketScanResponse(extracted=extracted, candidates=candidates)


# KOPIS 공연 검색 (keyword, start_date, end_date -> DB upsert)
@router.get("/search", response_model=list[ConcertResponse])
async def search_concerts(
    keyword: str = Query(...),
    start_date: date | None = Query(None),
    end_date: date | None = Query(None),
    db: AsyncSession = Depends(get_db),
):
    return await kopis_search(db, keyword, start_date, end_date)


# 공연 상세 조회 (DB -> KOPIS API + DB upsert)
@router.get("/{kopis_id}", response_model=ConcertResponse)
async def get_concert(kopis_id: str, db: AsyncSession = Depends(get_db)):
    # DB 조회
    result = await db.execute(select(Concert).where(Concert.kopis_id == kopis_id))
    concert = result.scalar_one_or_none()

    if concert is not None:
        return concert

    # KOPIS API
    return await get_concert_detail(db, kopis_id)
