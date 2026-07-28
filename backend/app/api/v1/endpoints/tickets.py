from uuid import UUID

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user, rate_limit_diary_generation, verify_llm_api_key
from app.models.ticket import Ticket
from app.models.user import User
from app.schemas.diary import DiaryResultRequest, DiaryResultResponse
from app.schemas.setlist import (
    RealSetlistResponse, PreSetlistResponse, SetlistFmCandidate,
    SetlistEditRequest, FetchSetlistRequest,
)
from app.schemas.ticket import TicketCreate, TicketListItem, TicketUpdate, TicketWithConcert
from app.services.crawler import crawl_and_save
from app.services.lastfm import ensure_artist_genres_cached
from app.services.pre_setlist import get_pre_setlist, generate_pre_setlist, update_pre_setlist
from app.services.setlist import (
    get_real_setlist,
    search_setlists_for_concert,
    fetch_and_save_real_setlist,
    update_real_setlist,
)
from app.services.ticket import (
    create_ticket,
    get_sorted_tickets,
    get_ticket,
    request_ticket_diary,
    update_ticket,
    delete_ticket,
)

router = APIRouter()


# 티켓 등록
@router.post("", response_model=TicketWithConcert, status_code=status.HTTP_201_CREATED)
async def register_ticket(
    body: TicketCreate,
    background_tasks: BackgroundTasks,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    ticket = await create_ticket(db, current_user, body)
    if ticket.ticketing_site:
        background_tasks.add_task(crawl_and_save, ticket.concert_id, ticket.ticketing_site)
    if ticket.concert and ticket.concert.artist_name:
        # 결산 "선호 장르"에 쓰일 아티스트가 이번에 처음 확정됐으니, 야간 배치를 기다리지 않고
        # 바로 캐싱(이미 캐싱된 아티스트면 ensure_artist_genres_cached 내부에서 스킵됨)
        background_tasks.add_task(ensure_artist_genres_cached, ticket.concert.artist_name)
    return ticket



# 내 티켓 목록 조회 (limit/offset은 선택 - 생략하면 기본 상한(200건) 적용)
@router.get("", response_model=list[TicketListItem])
async def list_tickets(
    limit: int = Query(200, ge=1, le=200),
    offset: int = Query(0, ge=0),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await get_sorted_tickets(db, current_user.id, limit=limit, offset=offset)


# 티켓 상세 조회
@router.get("/{ticket_id}", response_model=TicketWithConcert)
async def retrieve_ticket(
    ticket_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await get_ticket(db, current_user.id, ticket_id)


# 티켓 수정
@router.patch("/{ticket_id}", response_model=TicketWithConcert)
async def modify_ticket(
    ticket_id: UUID,
    body: TicketUpdate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await update_ticket(db, current_user, ticket_id, body)


# 티켓 -> (concert_id, 관람일) 추출. 관람일이 없고 공연이 여러 날짜에 걸치면 아래 setlist
# 서비스 함수들이 400으로 날짜 지정을 요구함(추측해서 엉뚱한 날짜의 셋리스트를 주지 않기 위함)
def _ticket_concert_and_date(ticket: Ticket):
    if ticket.concert_id is None:
        raise HTTPException(status_code=404, detail="공연 정보를 찾을 수 없습니다.")
    explicit_date = ticket.attended_date.date() if ticket.attended_date else None
    return ticket.concert_id, explicit_date


# 티켓 기준 실제 셋리스트 조회 (내부적으로 ticket.concert_id + attended_date로 위임)
@router.get("/{ticket_id}/setlist", response_model=RealSetlistResponse)
async def get_ticket_real_setlist(
    ticket_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    ticket = await get_ticket(db, current_user.id, ticket_id)
    concert_id, explicit_date = _ticket_concert_and_date(ticket)
    return await get_real_setlist(db, concert_id, explicit_date)


# 티켓 기준 Setlist.fm 후보 검색
@router.get("/{ticket_id}/setlist/search", response_model=list[SetlistFmCandidate])
async def search_ticket_real_setlists(
    ticket_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    ticket = await get_ticket(db, current_user.id, ticket_id)
    concert_id, explicit_date = _ticket_concert_and_date(ticket)
    return await search_setlists_for_concert(db, concert_id, explicit_date)


# 티켓 기준으로 Setlist.fm ID의 셋리스트를 가져와 저장
@router.post("/{ticket_id}/setlist", response_model=RealSetlistResponse, status_code=status.HTTP_201_CREATED)
async def fetch_ticket_real_setlist(
    ticket_id: UUID,
    body: FetchSetlistRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    ticket = await get_ticket(db, current_user.id, ticket_id)
    concert_id, explicit_date = _ticket_concert_and_date(ticket)
    return await fetch_and_save_real_setlist(db, concert_id, body.setlistfm_id, explicit_date)


# 티켓 기준 실제 셋리스트 유저 수정
@router.patch("/{ticket_id}/setlist", response_model=RealSetlistResponse)
async def edit_ticket_real_setlist(
    ticket_id: UUID,
    body: SetlistEditRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    ticket = await get_ticket(db, current_user.id, ticket_id)
    concert_id, explicit_date = _ticket_concert_and_date(ticket)
    return await update_real_setlist(db, concert_id, body.songs, current_user.nickname, explicit_date)


# 예상 셋리스트는 아티스트 과거 통계 기반 추측이라 날짜에 안 묶임 - ticket.concert_id로만 위임
@router.get("/{ticket_id}/setlist/pre", response_model=PreSetlistResponse)
async def get_ticket_pre_setlist(
    ticket_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    if not current_user.show_predicted_setlist:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="예상 셋리스트 표시가 비활성화되어 있습니다.")
    ticket = await get_ticket(db, current_user.id, ticket_id)
    concert_id, _ = _ticket_concert_and_date(ticket)
    return await get_pre_setlist(db, concert_id)


@router.post("/{ticket_id}/setlist/pre/generate", response_model=PreSetlistResponse, status_code=status.HTTP_201_CREATED)
async def generate_ticket_pre_setlist(
    ticket_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    if not current_user.show_predicted_setlist:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="예상 셋리스트 표시가 비활성화되어 있습니다.")
    ticket = await get_ticket(db, current_user.id, ticket_id)
    concert_id, _ = _ticket_concert_and_date(ticket)
    return await generate_pre_setlist(db, concert_id)


@router.patch("/{ticket_id}/setlist/pre", response_model=PreSetlistResponse)
async def edit_ticket_pre_setlist(
    ticket_id: UUID,
    body: SetlistEditRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    if not current_user.show_predicted_setlist:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="예상 셋리스트 표시가 비활성화되어 있습니다.")
    ticket = await get_ticket(db, current_user.id, ticket_id)
    concert_id, _ = _ticket_concert_and_date(ticket)
    return await update_pre_setlist(db, concert_id, body.songs, current_user.nickname)


# 한줄평 기반 공연 일기 생성 요청 (diary_requested_at만 찍어두고 즉시 반환 - 실제 LLM팀 전송은
# 자정 배치가 처리하므로, 클라이언트는 GET /tickets/{id}를 폴링해 diary가 채워지는 걸 확인해야 함)
@router.post("/{ticket_id}/diary", response_model=TicketWithConcert, status_code=status.HTTP_202_ACCEPTED)
async def create_ticket_diary(
    ticket_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
    _rate_limit: None = Depends(rate_limit_diary_generation),
):
    return await request_ticket_diary(db, current_user.id, ticket_id)


# LLM팀이 자정 배치로 처리한 공연 일기 결과를 전송하는 웹훅 엔드포인트
@router.post("/{ticket_id}/diary-result", response_model=DiaryResultResponse)
async def receive_diary_result(
    ticket_id: UUID,
    body: DiaryResultRequest,
    db: AsyncSession = Depends(get_db),
    _: None = Depends(verify_llm_api_key),
):
    result = await db.execute(select(Ticket).where(Ticket.id == ticket_id))
    ticket = result.scalar_one_or_none()
    if ticket is None:
        raise HTTPException(status_code=404, detail="티켓을 찾을 수 없습니다.")

    ticket.diary = body.diary
    await db.commit()
    return DiaryResultResponse(diary=ticket.diary)


# 티켓 삭제
@router.delete("/{ticket_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_ticket(
    ticket_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await delete_ticket(db, current_user.id, ticket_id)
