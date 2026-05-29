from uuid import UUID
from datetime import datetime, timezone, timedelta

from fastapi import HTTPException
from sqlalchemy import select, delete
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.concert import Concert
from app.models.notification import Notification, NotificationType
from app.models.ticket import Ticket, TicketStatus
from app.schemas.ticket import TicketCreate, TicketUpdate

KST = timezone(timedelta(hours=9))


# KST 기준 해당 날짜 오전 9시 UTC 반환
def _at_9am_kst(dt: datetime) -> datetime:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=KST)
    d = dt.astimezone(KST).replace(hour=9, minute=0, second=0, microsecond=0)
    return d.astimezone(timezone.utc)


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
    ticket = result.scalar_one()
    await schedule_ticket_notifications(db, ticket)
    return ticket


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

    for field, value in body.model_dump(exclude_unset=True).items():
        setattr(ticket, field, value)

    await db.commit()

    # concert 관계 포함해서 재조회
    result = await db.execute(
        select(Ticket).where(Ticket.id == ticket.id).options(selectinload(Ticket.concert))
    )
    ticket = result.scalar_one()
    await schedule_ticket_notifications(db, ticket)
    return ticket


# 티켓 삭제
async def delete_ticket(db: AsyncSession, user_id: UUID, ticket_id: UUID) -> None:
    result = await db.execute(
        select(Ticket).where(Ticket.id == ticket_id, Ticket.user_id == user_id)
    )
    ticket = result.scalar_one_or_none()
    if ticket is None:
        raise HTTPException(status_code=404, detail="티켓을 찾을 수 없습니다.")

    await db.execute(delete(Notification).where(Notification.ticket_id == ticket_id))
    await db.delete(ticket)
    await db.commit()


# 티켓 알림 스케줄 등록 (기존 미발송 알림 초기화 후 재등록)
async def schedule_ticket_notifications(db: AsyncSession, ticket: Ticket) -> None:
    concert = ticket.concert
    if concert is None:
        return

    # 기존 미발송 알림 제거 후 재생성
    await db.execute(
        delete(Notification).where(
            Notification.ticket_id == ticket.id,
            Notification.is_sent == False,  # noqa: E712
        )
    )

    now = datetime.now(timezone.utc)
    to_add: list[Notification] = []

    # 배송 예정일 알림 (배송일 오전 9시)
    if ticket.delivery_date is not None:
        scheduled = _at_9am_kst(ticket.delivery_date)
        if scheduled > now:
            to_add.append(Notification(
                user_id=ticket.user_id,
                ticket_id=ticket.id,
                type=NotificationType.DELIVERY_DAY,
                title=concert.name,
                body="티켓 배송 예정일이에요.",
                scheduled_at=scheduled,
            ))

    # 공연 하루 전 알림 (공연일 오전 9시)
    day_before = _at_9am_kst(concert.start_date - timedelta(days=1))
    if day_before > now:
        to_add.append(Notification(
            user_id=ticket.user_id,
            ticket_id=ticket.id,
            type=NotificationType.DAY_BEFORE,
            title=concert.name,
            body="내일 공연이에요.",
            scheduled_at=day_before,
        ))

    # 공연 당일 알림 (공연일 오전 9시)
    concert_day = _at_9am_kst(concert.start_date)
    if concert_day > now:
        to_add.append(Notification(
            user_id=ticket.user_id,
            ticket_id=ticket.id,
            type=NotificationType.CONCERT_DAY,
            title=concert.name,
            body="오늘 공연 날이에요.",
            scheduled_at=concert_day,
        ))

    for notif in to_add:
        db.add(notif)

    await db.commit()
