import json
from uuid import UUID
from datetime import datetime, timezone
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from sqlalchemy.orm import selectinload
from fastapi import HTTPException
from app.models.ticket import Ticket, TicketStatus
from app.models.concert import Concert
from app.schemas.ticket import TicketCreate, TicketUpdate


# concert_id로 공연 조회
async def _get_concert_by_id(db: AsyncSession, concert_id: UUID) -> Concert:
    result = await db.execute(select(Concert).where(Concert.id == concert_id))
    concert = result.scalar_one_or_none()
    if concert is None:
        raise HTTPException(status_code=404, detail="공연 정보를 찾을 수 없습니다.")
    return concert


# kopis_id로 공연 조회
async def _get_concert_by_kopis_id(db: AsyncSession, kopis_id: str) -> Concert:
    result = await db.execute(select(Concert).where(Concert.kopis_id == kopis_id))
    concert = result.scalar_one_or_none()
    if concert is None:
        raise HTTPException(status_code=404, detail="공연 정보를 찾을 수 없습니다.")
    return concert


# 티켓 등록
async def create_ticket(db: AsyncSession, user_id: UUID, body: TicketCreate) -> Ticket:
    if body.concert_id is not None:
        concert = await _get_concert_by_id(db, body.concert_id)
    else:
        concert = await _get_concert_by_kopis_id(db, body.kopis_id)

    # 동일 유저-공연 중복 등록 방지
    result = await db.execute(
        select(Ticket).where(Ticket.user_id == user_id, Ticket.concert_id == concert.id)
    )
    if result.scalar_one_or_none() is not None:
        raise HTTPException(status_code=409, detail="이미 등록된 공연 티켓입니다.")

    ticket = Ticket(
        user_id=user_id,
        concert_id=concert.id,
        delivery_date=body.delivery_date,
        ticketing_site=body.ticketing_site,
        price=body.price,
        seat_type=body.seat_type,
    )
    db.add(ticket)
    await db.commit()

    # concert 관계 포함해서 재조회
    result = await db.execute(
        select(Ticket).where(Ticket.id == ticket.id).options(selectinload(Ticket.concert))
    )
    return result.scalar_one()


# 내 티켓 목록 조회 (공연전 티켓 먼저, 공연일 기준 현재와 가까운 순)
async def get_sorted_tickets(db: AsyncSession, user_id: UUID) -> list[Ticket]:
    result = await db.execute(
        select(Ticket)
        .where(Ticket.user_id == user_id)
        .options(selectinload(Ticket.concert))
    )
    tickets = list(result.scalars().all())

    now = datetime.now(timezone.utc)

    # 공연 상태 및 날짜 기준으로 정렬
    def _sort_key(ticket: Ticket) -> tuple:

        # 공연 전/후 구분 (공연 전이 먼저)
        is_after = 1 if ticket.status == TicketStatus.AFTER_CONCERT else 0

        # 공연일과 현재 시간 차이 (공연일이 가까운 순)
        if ticket.concert is not None:
            concert_date = ticket.concert.start_date
            if concert_date.tzinfo is None:
                concert_date = concert_date.replace(tzinfo=timezone.utc)
            diff = abs((concert_date - now).total_seconds())
        else:
            diff = float("inf")
        return (is_after, diff)

    return sorted(tickets, key=_sort_key)


# 티켓 단일 조회
async def get_ticket(db: AsyncSession, user_id: UUID, ticket_id: UUID) -> Ticket:
    result = await db.execute(
        select(Ticket)
        .where(Ticket.id == ticket_id, Ticket.user_id == user_id)
        .options(selectinload(Ticket.concert))
    )
    ticket = result.scalar_one_or_none()
    if ticket is None:
        raise HTTPException(status_code=404, detail="티켓을 찾을 수 없습니다.")
    return ticket


# 티켓 수정
async def update_ticket(
    db: AsyncSession, user_id: UUID, ticket_id: UUID, body: TicketUpdate
) -> Ticket:
    result = await db.execute(
        select(Ticket)
        .where(Ticket.id == ticket_id, Ticket.user_id == user_id)
        .options(selectinload(Ticket.concert))
    )
    ticket = result.scalar_one_or_none()
    if ticket is None:
        raise HTTPException(status_code=404, detail="티켓을 찾을 수 없습니다.")

    # body에서 전달된 필드만 업데이트
    for field, value in body.model_dump(exclude_unset=True).items():
        # concert_photo_urls는 DB에 JSON 문자열로 저장
        if field == "concert_photo_urls":
            setattr(ticket, field, json.dumps(value) if value is not None else None)
        else:
            setattr(ticket, field, value)

    await db.commit()

    # concert 관계 포함해서 재조회
    result = await db.execute(
        select(Ticket).where(Ticket.id == ticket.id).options(selectinload(Ticket.concert))
    )
    return result.scalar_one()


# 티켓 삭제
async def delete_ticket(db: AsyncSession, user_id: UUID, ticket_id: UUID) -> None:
    result = await db.execute(
        select(Ticket).where(Ticket.id == ticket_id, Ticket.user_id == user_id)
    )
    ticket = result.scalar_one_or_none()
    if ticket is None:
        raise HTTPException(status_code=404, detail="티켓을 찾을 수 없습니다.")

    await db.delete(ticket)
    await db.commit()


# 티켓 알림 스케줄 등록 추후 구현
async def schedule_ticket_notifications(db: AsyncSession, ticket: Ticket) -> None:
    pass
