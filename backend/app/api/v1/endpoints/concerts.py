from datetime import date, timedelta

from fastapi import APIRouter, Depends, Query, Request, UploadFile, File, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

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
        artist=extracted_raw.get("artist") or [],
        date=extracted_raw.get("date"),
        time=extracted_raw.get("time"),
        location=extracted_raw.get("location"),
        seat=extracted_raw.get("seat"),
        platform=extracted_raw.get("platform"),
        price=extracted_raw.get("price"),
        shipping_date=extracted_raw.get("shipping_date"),
        event_type=extracted_raw.get("event_type"),
    )

    # 추출된 정보 기반으로 KOPIS에서 공연 후보 검색 (아티스트명 또는 공연명 기준, 공연일 앞 뒤 7일)
    candidates = []
    search_keyword = extracted.artist[0] if extracted.artist else extracted.title
    if search_keyword:
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
            candidates = await kopis_search(db, search_keyword, start_date, end_date)
        except HTTPException:
            pass

    # KOPIS artist 크로스체크: OCR 추출 실패 시 후보에서 보완
    if not extracted.artist and candidates:
        # A: DB에 이미 artist_name이 있는 후보 사용
        for candidate in candidates:
            if candidate.artist_name:
                extracted.artist = candidate.artist_name
                break

        # B: 여전히 비어있고 후보가 정확히 1개뿐이면 상세 API 호출
        if not extracted.artist and len(candidates) == 1:
            try:
                detail = await get_concert_detail(db, candidates[0].kopis_id)
                if detail.artist_name:
                    extracted.artist = detail.artist_name
                    candidates = [detail]
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
