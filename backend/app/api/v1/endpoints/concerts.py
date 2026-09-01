from datetime import date, timedelta
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Request, UploadFile, File, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import (
    get_current_user,
    is_within_scan_cooldown,
    rate_limit_ticket_scan,
    record_meaningful_ticket_scan,
)
from app.models.artist_normalization import ArtistNormalizationStatus, CanonicalArtist
from app.models.concert import Concert
from app.models.user import User
from app.schemas.concert import (
    ArtistNameConfirmRequest,
    ArtistNameConfirmResponse,
    ConcertResponse,
    TicketScanExtracted,
    TicketScanResponse,
)
from app.services.artist_blocklist import is_blocklisted_artist_name
from app.services.artist_matching import normalize_artist_names
from app.services.artist_normalization import _register_alias_if_new, apply_canonical_replacement
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
    _rate_limit: None = Depends(rate_limit_ticket_scan),
):
    # Content-Length 헤더로 다운로드 전 사전 거절
    content_length = request.headers.get("content-length")
    if content_length and int(content_length) > _MAX_IMAGE_SIZE:
        raise HTTPException(status_code=413, detail="이미지 크기는 10MB를 초과할 수 없습니다.")

    # 최대 10MB+1 바이트만 읽어 초과 여부 판단
    image_bytes = await image.read(_MAX_IMAGE_SIZE + 1)
    if len(image_bytes) > _MAX_IMAGE_SIZE:
        raise HTTPException(status_code=413, detail="이미지 크기는 10MB를 초과할 수 없습니다.")

    # 카메라 정렬 오인식으로 짧은 간격에 연달아 들어온 요청이면, 유료 Vision 호출 없이
    # 빈 결과로 바로 응답 (is_within_scan_cooldown 주석 참고)
    if is_within_scan_cooldown(current_user.id):
        return TicketScanResponse(extracted=TicketScanExtracted(), candidates=[])

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

    # 티켓이 아닌 사물(카메라 정렬 인식 오탐)을 찍어서 아무 필드도 못 뽑은 스캔은
    # "진짜 스캔 시도" 한도(record_meaningful_ticket_scan)를 깎지 않음
    if any(
        [
            extracted.title,
            extracted.date,
            extracted.location,
            extracted.seat,
            extracted.platform,
            extracted.price,
        ]
    ):
        record_meaningful_ticket_scan(current_user.id)

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

    # 목록 검색(/search)으로만 upsert된 공연은 KOPIS 상세 API를 아직 한 번도 안 불러서
    # artist_name/price/description 등이 비어있으므로, 이 경우엔 캐시를 쓰지 않고 상세 조회함
    if concert is not None and concert.kopis_detail_synced_at is not None:
        return concert

    # KOPIS API
    return await get_concert_detail(db, kopis_id)


# 미확정(MusicBrainz로 못 찾은) 아티스트 표기를 유저가 직접 확정하는 API(G안, 프론트 UI는 아직
# 없음) - 실제 관람 유저가 크롤러/LLM보다 정확한 소스라는 전제. 로그인만 하면 아무 공연이나
# 고칠 수 있는 건 프로토타입 단계라 임시 허용한 것(런칭 전 티켓 보유자 제한 등 정책 재검토 필요)
@router.patch("/{concert_id}/artist-name/confirm", response_model=ArtistNameConfirmResponse)
async def confirm_artist_name(
    concert_id: UUID,
    body: ArtistNameConfirmRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(select(Concert).where(Concert.id == concert_id))
    concert = result.scalar_one_or_none()
    if concert is None:
        raise HTTPException(status_code=404, detail="공연 정보를 찾을 수 없습니다.")

    original_name = body.original_name.strip()
    confirmed_name = body.confirmed_name.strip()
    if not original_name or not confirmed_name:
        raise HTTPException(status_code=400, detail="아티스트명이 비어있습니다.")
    if original_name not in (concert.artist_name or []):
        raise HTTPException(status_code=400, detail="해당 아티스트가 이 공연에 없습니다.")
    if is_blocklisted_artist_name(confirmed_name):
        raise HTTPException(status_code=400, detail="아티스트명으로 쓸 수 없는 값입니다.")

    # 기존 canonical 표기들과 퍼지/로마자 매칭해서 근접 중복(오타, 대소문자 등)이면 새로
    # 만들지 않고 기존 것을 재사용 - artist_matching.py가 concert.artist_name 병합 때 쓰는
    # 것과 동일한 로직/임계치를 그대로 재사용(이중 기준을 두지 않기 위함)
    existing_canonicals = (await db.execute(select(CanonicalArtist))).scalars().all()
    canonical_names = {c.canonical_name for c in existing_canonicals}
    resolved_name = normalize_artist_names([confirmed_name], canonical_names)[0]

    canonical = next((c for c in existing_canonicals if c.canonical_name == resolved_name), None)
    if canonical is None:
        canonical = CanonicalArtist(mbid=None, canonical_name=resolved_name)
        db.add(canonical)
        await db.flush()

    for alias_text in {original_name, confirmed_name}:
        await _register_alias_if_new(db, canonical, alias_text, source="user_input")

    await apply_canonical_replacement(db, concert_id, original_name, resolved_name)

    status_result = await db.execute(
        select(ArtistNormalizationStatus).where(
            ArtistNormalizationStatus.concert_id == concert_id,
            ArtistNormalizationStatus.artist_text == original_name,
        )
    )
    status_row = status_result.scalar_one_or_none()
    if status_row is not None:
        status_row.status = "matched"

    await db.commit()
    await db.refresh(concert)
    return ArtistNameConfirmResponse(artist_name=concert.artist_name)
