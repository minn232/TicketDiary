from uuid import UUID

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user, rate_limit_diary_generation, verify_llm_api_key
from app.models.ticket import Ticket
from app.models.user import User
from app.schemas.diary import DiaryResultRequest, DiaryResultResponse
from app.schemas.ticket import TicketCreate, TicketListItem, TicketUpdate, TicketWithConcert
from app.services.crawler import crawl_and_save
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
