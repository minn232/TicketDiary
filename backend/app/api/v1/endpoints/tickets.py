from uuid import UUID
from fastapi import APIRouter, Depends, status
from sqlalchemy.ext.asyncio import AsyncSession
from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.user import User
from app.schemas.ticket import TicketCreate, TicketUpdate, TicketWithConcert
from app.services.ticket import (
    create_ticket,
    get_sorted_tickets,
    get_ticket,
    update_ticket,
    delete_ticket,
    schedule_ticket_notifications,
)

router = APIRouter()


# 티켓 등록
@router.post("", response_model=TicketWithConcert, status_code=status.HTTP_201_CREATED)
async def register_ticket(
    body: TicketCreate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    ticket = await create_ticket(db, current_user.id, body)
    await schedule_ticket_notifications(db, ticket)
    return ticket


# 내 티켓 목록 조회
@router.get("", response_model=list[TicketWithConcert])
async def list_tickets(
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await get_sorted_tickets(db, current_user.id)


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
    return await update_ticket(db, current_user.id, ticket_id, body)


# 티켓 삭제
@router.delete("/{ticket_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_ticket(
    ticket_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await delete_ticket(db, current_user.id, ticket_id)
