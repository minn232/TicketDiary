from uuid import UUID
from datetime import datetime, timezone, timedelta
import difflib
import logging
import re

from fastapi import HTTPException
from sqlalchemy import case, func, select, delete
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.concert import Concert
from app.models.notification import Notification, NotificationType
from app.models.ticket import Ticket, TicketStatus
from app.models.user import User
from app.schemas.ticket import TicketCreate, TicketUpdate

logger = logging.getLogger(__name__)
KST = timezone(timedelta(hours=9))


# concert.end_date 기준 초기 티켓 상태 결정
# KOPIS end_date는 UTC 자정으로 저장되므로 +15h(=KST 다음날 자정)가 지나면 공연 종료로 판단
def _initial_status(concert: Concert) -> TicketStatus:
    now = datetime.now(timezone.utc)
    if concert.end_date + timedelta(hours=15) < now:
        return TicketStatus.AFTER_CONCERT
    return TicketStatus.BEFORE_CONCERT


# KST 기준 해당 날짜 오전 9시 UTC 반환
def _at_9am_kst(dt: datetime) -> datetime:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=KST)
    d = dt.astimezone(KST).replace(hour=9, minute=0, second=0, microsecond=0)
    return d.astimezone(timezone.utc)


# seat_type 문자열에서 좌석 등급 부분만 추출 ("R석 A구역 12열 15번" -> "R석")
_SEAT_GRADE_TOKEN_RE = re.compile(r"[A-Z가-힣]{1,5}석")


# OCR/사용자가 입력한 seat_type의 등급 부분을 concert.price(크롤링으로 받은 실제 가격표
# 등급명 목록)와 대조해서 다르면 크롤링 값으로 교정. 사진 OCR은 화질/각도 때문에 글자가
# 깨지기 쉬운 반면(예: "지정석"이 "아지정석"으로 잘못 인식) 크롤링은 예매 사이트 가격표를
# 그대로 읽으므로 등급명 표기가 더 정확하다고 보고 크롤링 쪽을 신뢰함
# (반대로 start_time은 OCR을 신뢰함 - 실물 티켓이 실제 회차를 증명하는 자료이기 때문.
# 필드 성격이 달라 신뢰 방향도 반대)
def _correct_seat_type(seat_type: str | None, concert: Concert) -> str | None:
    if not seat_type or not concert.price:
        return seat_type

    known_grades = [p.get("seat_type") for p in concert.price if p.get("seat_type")]
    if not known_grades:
        return seat_type

    m = _SEAT_GRADE_TOKEN_RE.search(seat_type)
    if not m:
        return seat_type
    token = m.group(0)

    if token in known_grades:
        return seat_type

    # 부분 포함부터 확인 (예: OCR이 "아지정석"처럼 앞글자를 잘못 붙인 경우)
    corrected = next((g for g in known_grades if g in token or token in g), None)
    if corrected is None:
        matches = difflib.get_close_matches(token, known_grades, n=1, cutoff=0.6)
        corrected = matches[0] if matches else None

    if corrected is None or corrected == token:
        return seat_type

    logger.warning(
        f"티켓 좌석등급 불일치 (concert_id={concert.id}): OCR={token!r} 크롤링={corrected!r} -> 크롤링 값 사용"
    )
    return seat_type[: m.start()] + corrected + seat_type[m.end():]


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
async def create_ticket(db: AsyncSession, user: User, body: TicketCreate) -> Ticket:
    if body.concert_id is not None:
        concert = await _get_concert_by_id(db, body.concert_id)
    else:
        concert = await _get_concert_by_kopis_id(db, body.kopis_id)

    # 동일 유저-공연 중복 등록 방지
    result = await db.execute(
        select(Ticket).where(Ticket.user_id == user.id, Ticket.concert_id == concert.id)
    )
    if result.scalar_one_or_none() is not None:
        raise HTTPException(status_code=409, detail="이미 등록된 공연 티켓입니다.")

    # 실제 티켓(OCR)이 회차를 증명하는 자료이므로 KOPIS 시간과 다르면 OCR을 신뢰하고 로그만 남김
    start_time = body.start_time
    if start_time and concert.start_time and start_time != concert.start_time:
        logger.warning(
            f"티켓 시작시간 불일치 (concert_id={concert.id}): "
            f"KOPIS={concert.start_time} OCR={start_time} -> OCR 값 사용"
        )
    if not start_time:
        start_time = concert.start_time
    elif concert.start_time is None:
        concert.start_time = start_time

    # 배송일은 예매 사이트 공지(크롤링)가 실물 티켓 OCR보다 신뢰도가 높다고 보고,
    # OCR/유저 입력이 없을 때만 크롤링된 concert.delivery_date로 채움 (seat_type과 같은 방향)
    delivery_date = body.delivery_date
    if delivery_date is None:
        delivery_date = concert.delivery_date

    ticket = Ticket(
        user_id=user.id,
        concert_id=concert.id,
        status=_initial_status(concert),
        delivery_date=delivery_date,
        start_time=start_time,
        ticketing_site=body.ticketing_site,
        price=body.price,
        seat_type=_correct_seat_type(body.seat_type, concert),
    )
    try:
        db.add(ticket)
        await db.commit()
    except IntegrityError:
        await db.rollback()
        raise HTTPException(status_code=409, detail="이미 등록된 공연 티켓입니다.")

    # concert 관계 포함해서 재조회
    result = await db.execute(
        select(Ticket).where(Ticket.id == ticket.id).options(selectinload(Ticket.concert))
    )
    ticket = result.scalar_one()
    await schedule_ticket_notifications(db, ticket, user)
    return ticket


# 내 티켓 목록 조회 (공연전 티켓 먼저, 공연일 기준 현재와 가까운 순)
async def get_sorted_tickets(db: AsyncSession, user_id: UUID) -> list[Ticket]:
    result = await db.execute(
        select(Ticket)
        .outerjoin(Concert, Ticket.concert_id == Concert.id)
        .where(Ticket.user_id == user_id)
        .options(selectinload(Ticket.concert))
        .order_by(
            case((Ticket.status == TicketStatus.AFTER_CONCERT, 1), else_=0).asc(),
            func.abs(func.extract("epoch", Concert.start_date - func.now())).asc().nulls_last(),
        )
    )
    return list(result.scalars().all())


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
    db: AsyncSession, user: User, ticket_id: UUID, body: TicketUpdate
) -> Ticket:
    result = await db.execute(
        select(Ticket)
        .where(Ticket.id == ticket_id, Ticket.user_id == user.id)
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
    await schedule_ticket_notifications(db, ticket, user)
    return ticket


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


# 유저 알림 설정에서 delivery/before_concert 활성화 여부 반환
def _get_notif_flags(user: User) -> tuple[bool, bool]:
    settings = user.notification_settings
    if isinstance(settings, str):
        import json
        settings = json.loads(settings)
    if not isinstance(settings, dict):
        return True, True
    return settings.get("delivery", True), settings.get("before_concert", True)


# 티켓 알림 스케줄 등록 (기존 미발송 알림 초기화 후 재등록)
async def schedule_ticket_notifications(db: AsyncSession, ticket: Ticket, user: User) -> None:
    concert = ticket.concert
    if concert is None:
        return

    delivery_on, before_concert_on = _get_notif_flags(user)

    # 기존 미발송 알림 제거 후 재생성
    await db.execute(
        delete(Notification).where(
            Notification.ticket_id == ticket.id,
            Notification.is_sent == False,  # noqa: E712
        )
    )

    now = datetime.now(timezone.utc)
    to_add: list[Notification] = []

    # 배송 예정일 알림 (delivery 설정 on, 배송일 오전 9시)
    if delivery_on and ticket.delivery_date is not None:
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

    # 공연 하루 전 알림 (before_concert 설정 on, 공연 전날 오전 9시)
    if before_concert_on:
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

    # 공연 당일 알림 (before_concert 설정 on, 공연일 오전 9시)
    if before_concert_on:
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


# 크롤링으로 concert.delivery_date가 새로 채워졌을 때(crawl-result 웹훅에서 호출), 이미 등록된
# 티켓 중 자체 delivery_date가 없는 것들(OCR로 못 뽑았거나 안 넣은 경우)에 백필하고
# DELIVERY_DAY 등 알림을 재스케줄. 이미 자체 값이 있는 티켓은 건드리지 않음(OCR 값 우선순위 유지)
async def backfill_delivery_date_from_concert(
    db: AsyncSession, concert_id: UUID, delivery_date: datetime
) -> None:
    result = await db.execute(
        select(Ticket)
        .options(selectinload(Ticket.concert), selectinload(Ticket.user))
        .where(Ticket.concert_id == concert_id, Ticket.delivery_date.is_(None))
    )
    tickets = result.scalars().all()
    if not tickets:
        return

    for ticket in tickets:
        ticket.delivery_date = delivery_date
    await db.commit()

    for ticket in tickets:
        await schedule_ticket_notifications(db, ticket, ticket.user)


# BEFORE_CONCERT 티켓 중 공연이 끝난 것을 AFTER_CONCERT로 자동 전환
# KOPIS end_date는 UTC 자정 저장이므로 +15h(KST 다음날 자정) 기준으로 판단
async def sync_ticket_statuses(db: AsyncSession) -> None:
    now = datetime.now(timezone.utc)
    result = await db.execute(
        select(Ticket)
        .join(Concert, Ticket.concert_id == Concert.id)
        .where(
            Ticket.status == TicketStatus.BEFORE_CONCERT,
            Concert.end_date + timedelta(hours=15) < now,
        )
    )
    tickets = result.scalars().all()
    for ticket in tickets:
        ticket.status = TicketStatus.AFTER_CONCERT
    if tickets:
        await db.commit()
        logger.info(f"티켓 상태 자동 전환: {len(tickets)}건 → AFTER_CONCERT")
