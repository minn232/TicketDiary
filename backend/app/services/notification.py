import asyncio
import logging
from uuid import UUID
from datetime import datetime, timedelta, timezone

from fastapi import HTTPException
from sqlalchemy import delete, func, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.models.concert import Concert
from app.models.notification import Notification, NotificationType
from app.models.social import ConcertFollow
from app.models.ticket import Ticket
from app.models.user import User
from app.schemas.notification import NotificationResponse

logger = logging.getLogger(__name__)

_firebase_initialized = False


# Firebase 초기화
def _init_firebase() -> None:
    global _firebase_initialized
    if _firebase_initialized:
        return
    try:
        import firebase_admin
        from firebase_admin import credentials
        if not firebase_admin._apps:
            cred = credentials.Certificate(settings.FIREBASE_CREDENTIALS_PATH)
            firebase_admin.initialize_app(cred)
        _firebase_initialized = True
    except Exception as e:
        logger.error(f"Firebase 초기화 실패: {e}")


# 알림 목록 조회. 아직 발송 안 된(is_sent=False) 예약 항목은 "받은 알림"이
# 아니라서 제외 — 예전엔 이 필터가 없어서 몇 주 뒤 예약된 알림까지 인앱
# 알림함에 "오늘 공연 날이에요" 같은 문구로 떠서 이미 온 것처럼 보이는
# 문제가 있었음(실기기 테스트로 발견).
# 발송된 알림은 지우지 않고 쌓여서, 응답이 계속 커지지 않도록 기본 상한을 둠
_DEFAULT_NOTIFICATION_LIST_LIMIT = 200


# 응답에 공연 id/포스터를 붙임(눌렀을 때 이동·썸네일용) - 티켓 알림은 concert_id가 비어 있어 티켓의 공연으로
async def get_notifications(
    db: AsyncSession, user_id: UUID, limit: int = _DEFAULT_NOTIFICATION_LIST_LIMIT, offset: int = 0
) -> list[dict]:
    concert_id = func.coalesce(Notification.concert_id, Ticket.concert_id)
    result = await db.execute(
        select(Notification, Concert.id, Concert.poster_url)
        .outerjoin(Ticket, Ticket.id == Notification.ticket_id)
        .outerjoin(Concert, Concert.id == concert_id)
        .where(Notification.user_id == user_id, Notification.is_sent == True)  # noqa: E712
        .order_by(Notification.scheduled_at.desc())
        .limit(limit)
        .offset(offset)
    )
    return [
        {**NotificationResponse.model_validate(n).model_dump(), "concert_id": cid, "poster_url": poster}
        for n, cid, poster in result.all()
    ]


# 안 읽은 알림 수 (설정 메뉴 배지용) - 목록과 같은 기준(발송된 것만)
async def count_unread(db: AsyncSession, user_id: UUID) -> int:
    result = await db.execute(
        select(func.count()).select_from(Notification).where(
            Notification.user_id == user_id,
            Notification.is_sent == True,  # noqa: E712
            Notification.is_read == False,  # noqa: E712
        )
    )
    return result.scalar_one()


# 알림함 "모두 읽음" - 발송된 안 읽은 알림 전부, 바뀐 건수 반환
async def mark_all_as_read(db: AsyncSession, user_id: UUID) -> int:
    result = await db.execute(
        update(Notification)
        .where(
            Notification.user_id == user_id,
            Notification.is_sent == True,  # noqa: E712
            Notification.is_read == False,  # noqa: E712
        )
        .values(is_read=True)
    )
    await db.commit()
    return result.rowcount


# 지난 지 오래된 알림 정리(매일 배치) - 발송된 지 30일이 넘었고 공연도 끝난 지 30일이 넘은 것만 지움.
# 공연이 아직 남은 알림(먼저 온 새 공연·티켓팅 소식)은 남겨서 공연 전에 다시 볼 수 있게 함
_NOTIFICATION_RETENTION = timedelta(days=30)


async def cleanup_old_notifications(db: AsyncSession) -> int:
    cutoff = datetime.now(timezone.utc) - _NOTIFICATION_RETENTION
    stale = (
        select(Notification.id)
        .outerjoin(Ticket, Ticket.id == Notification.ticket_id)
        .outerjoin(Concert, Concert.id == func.coalesce(Notification.concert_id, Ticket.concert_id))
        .where(
            Notification.is_sent == True,  # noqa: E712
            Notification.scheduled_at < cutoff,
            or_(Concert.id.is_(None), Concert.end_date < cutoff),
        )
    )
    result = await db.execute(delete(Notification).where(Notification.id.in_(stale)))
    await db.commit()
    return result.rowcount


# 알림 읽음 처리
async def mark_as_read(db: AsyncSession, user_id: UUID, notification_id: UUID) -> Notification:
    result = await db.execute(
        select(Notification).where(
            Notification.id == notification_id,
            Notification.user_id == user_id,
        )
    )
    notif = result.scalar_one_or_none()
    if notif is None:
        raise HTTPException(status_code=404, detail="알림을 찾을 수 없습니다.")
    notif.is_read = True
    await db.commit()
    return notif


# 알림 삭제
async def delete_notification(db: AsyncSession, user_id: UUID, notification_id: UUID) -> None:
    result = await db.execute(
        select(Notification).where(
            Notification.id == notification_id,
            Notification.user_id == user_id,
        )
    )
    notif = result.scalar_one_or_none()
    if notif is None:
        raise HTTPException(status_code=404, detail="알림을 찾을 수 없습니다.")
    await db.delete(notif)
    await db.commit()


# FCM 발송 결과 - 만료 토큰(앱 삭제/재설치 등)은 재시도해도 계속 실패하므로 일시 오류와 구분
_FCM_SENT = "sent"
_FCM_INVALID_TOKEN = "invalid_token"
_FCM_FAILED = "failed"


# FCM 푸시 발송
def _send_fcm(token: str, title: str, body: str) -> str:
    try:
        _init_firebase()
        from firebase_admin import messaging
    except ImportError as e:
        logger.error(f"FCM 발송 실패: {e}")
        return _FCM_FAILED
    try:
        message = messaging.Message(
            notification=messaging.Notification(title=title, body=body),
            token=token,
        )
        messaging.send(message)
        return _FCM_SENT
    except (messaging.UnregisteredError, messaging.SenderIdMismatchError) as e:
        logger.info(f"FCM 만료 토큰, 토큰 삭제 예정: {e}")
        return _FCM_INVALID_TOKEN
    except Exception as e:
        logger.error(f"FCM 발송 실패: {e}")
        return _FCM_FAILED


_KST = timezone(timedelta(hours=9))


# 받침 있으면 첫 번째, 없으면 두 번째 조사(이/가 등) - 한글이 아니면(영문 단계명 등) 받침 없는 쪽
def _particle(word: str, with_final: str, without_final: str) -> str:
    last = word.strip()[-1:] if word.strip() else ""
    if "가" <= last <= "힣" and (ord(last) - ord("가")) % 28:
        return with_final
    return without_final


# 알림 본문의 공연장 - KOPIS 공연장명은 "올림픽공원 (올림픽홀)"처럼 괄호가 붙어 길어서 앞부분만
def _short_venue(venue: str | None) -> str | None:
    short = (venue or "").split(" (")[0].strip()
    return short or None


# 공연 전날/당일 알림 본문 - "내일 19:00 올림픽공원에서 공연이 있어요." (시각/장소는 있을 때만)
def concert_reminder_body(day: str, start_time: str | None, venue: str | None) -> str:
    when = f"{day} {start_time}" if start_time else day
    short = _short_venue(venue)
    return f"{when} {short}에서 공연이 있어요." if short else f"{when} 공연이 있어요."


# 티켓팅 알림 본문 - 그날 열리는 예매 단계 이름과 시각을 넣음("오늘 20:00 팬클럽 선예매가 열려요!").
# 시각을 모르는 티켓팅일은 날짜만 UTC 자정(KST 09:00)으로 저장돼서 그 시각이면 시각을 뺌
def ticketing_day_body(concert: Concert) -> str:
    opens = concert.ticketing_date
    if opens.tzinfo is None:
        opens = opens.replace(tzinfo=timezone.utc)
    opens = opens.astimezone(_KST)
    time = None if (opens.hour, opens.minute) == (9, 0) else opens.strftime("%H:%M")
    day = opens.date().isoformat()
    phase = next(
        (p["phase"] for p in concert.ticketing_phases or [] if p.get("date") == day and p.get("phase")), None
    )
    what = phase or "티켓팅"
    when = f"오늘 {time}" if time else "오늘"
    return f"{when} {what}{_particle(what, '이', '가')} 열려요! 미리 준비하세요."


# 신규 공연 알림 본문 - 공연 날짜/장소를 붙임("NELL의 새 공연이 등록됐어요 · 12.31 잠실학생체육관")
def new_concert_body(artist: str, concert: Concert) -> str:
    start = concert.start_date
    if start.tzinfo is None:
        start = start.replace(tzinfo=timezone.utc)
    start = start.astimezone(_KST)
    detail = " ".join(x for x in (f"{start.month}.{start.day}", _short_venue(concert.venue)) if x)
    return f"{artist}의 새 공연이 등록됐어요 · {detail}"


def _at_9am_kst(dt: datetime) -> datetime:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=_KST)
    d = dt.astimezone(_KST).replace(hour=9, minute=0, second=0, microsecond=0)
    return d.astimezone(timezone.utc)


# 찜한 공연 팔로워에게 TICKETING_DAY 알림 생성 (crawl-result 웹훅에서 호출)
async def schedule_ticketing_day_notifications(db: AsyncSession, concert_id: UUID) -> None:
    result = await db.execute(select(Concert).where(Concert.id == concert_id))
    concert = result.scalar_one_or_none()
    if concert is None or concert.ticketing_date is None:
        return

    scheduled = _at_9am_kst(concert.ticketing_date)
    now = datetime.now(timezone.utc)
    if scheduled <= now:
        logger.info(f"티켓팅 날짜가 이미 지났습니다: {concert.name}")
        return

    # 이 공연을 찜한 유저 조회
    rows_result = await db.execute(
        select(ConcertFollow, User)
        .join(User, ConcertFollow.user_id == User.id)
        .where(ConcertFollow.concerts.contains([{"concert_id": str(concert_id)}]))
    )
    rows = rows_result.all()
    if not rows:
        return

    # 기존 미발송 TICKETING_DAY 알림 삭제 (날짜 변경 재전송 대비)
    matched_user_ids = [user.id for _, user in rows]
    await db.execute(
        delete(Notification).where(
            Notification.user_id.in_(matched_user_ids),
            Notification.concert_id == concert_id,
            Notification.type == NotificationType.TICKETING_DAY,
            Notification.is_sent == False,  # noqa: E712
        )
    )

    for _, user in rows:
        notif_settings = user.notification_settings or {}
        if not notif_settings.get("ticketing", True):
            continue
        db.add(Notification(
            user_id=user.id,
            concert_id=concert_id,
            type=NotificationType.TICKETING_DAY,
            title=concert.name,
            body=ticketing_day_body(concert),
            scheduled_at=scheduled,
        ))

    await db.commit()
    logger.info(f"티켓팅 알림 생성: {concert.name} ({len(rows)}명)")


# 꺼뒀던 티켓팅 알림을 다시 켰을 때 찜한 공연 중 티켓팅일이 안 지난 것의 알림을 다시 예약함
# (NEW_CONCERT는 신규 공연 발견 시점에만 생기는 알림이라 되살릴 대상이 없음)
async def reschedule_user_ticketing_notifications(db: AsyncSession, user: User) -> None:
    follow = (
        await db.execute(select(ConcertFollow).where(ConcertFollow.user_id == user.id))
    ).scalar_one_or_none()
    concert_ids = [UUID(c["concert_id"]) for c in (follow.concerts if follow else []) if c.get("concert_id")]

    await db.execute(
        delete(Notification).where(
            Notification.user_id == user.id,
            Notification.type == NotificationType.TICKETING_DAY,
            Notification.is_sent == False,  # noqa: E712
        )
    )
    if not concert_ids:
        return

    now = datetime.now(timezone.utc)
    result = await db.execute(
        select(Concert).where(Concert.id.in_(concert_ids), Concert.ticketing_date.isnot(None))
    )
    for concert in result.scalars().all():
        scheduled = _at_9am_kst(concert.ticketing_date)
        if scheduled <= now:
            continue
        db.add(Notification(
            user_id=user.id,
            concert_id=concert.id,
            type=NotificationType.TICKETING_DAY,
            title=concert.name,
            body=ticketing_day_body(concert),
            scheduled_at=scheduled,
        ))


# 팔로우한 아티스트의 신규 공연에 NEW_CONCERT 알림 생성 - KOPIS 일별 배치가 "진짜 신규"
# 공연을 발견했을 때만 호출(온디맨드 조회/검색 경로에선 호출 안 함, 무관한 조회로 뜻하지
# 않게 발송되는 걸 막기 위함). matched는 kopis.py가 뉴스피드용으로 이미 계산해둔 (팔로워
# user_id, 매칭된 아티스트명) 목록을 그대로 받아 재계산 안 함.
async def schedule_new_concert_notifications(
    db: AsyncSession, concert: Concert, matched: list[tuple[UUID, str]]
) -> None:
    if not matched:
        return

    # 팔로우 아티스트 여러 명이 같은 공연(페스티벌 등)에 겹쳐도 유저당 알림은 한 번만
    # (먼저 매칭된 아티스트명으로 문구를 만듦)
    artist_by_user: dict[UUID, str] = {}
    for user_id, artist_name in matched:
        artist_by_user.setdefault(user_id, artist_name)

    result = await db.execute(select(User).where(User.id.in_(artist_by_user.keys())))
    users = result.scalars().all()
    if not users:
        return

    # 기존 미발송 NEW_CONCERT 알림 삭제 (같은 공연이 배치에서 두 번 "신규"로 감지돼도 중복 발송 방지)
    await db.execute(
        delete(Notification).where(
            Notification.user_id.in_([u.id for u in users]),
            Notification.concert_id == concert.id,
            Notification.type == NotificationType.NEW_CONCERT,
            Notification.is_sent == False,  # noqa: E712
        )
    )

    # 자정 배치 직후 바로 보내면 새벽에 푸시가 뜨므로 그날 오전 9시로 예약
    scheduled = _at_9am_kst(datetime.now(timezone.utc))

    for user in users:
        notif_settings = user.notification_settings or {}
        if not notif_settings.get("new_concert", True):
            continue
        db.add(Notification(
            user_id=user.id,
            concert_id=concert.id,
            type=NotificationType.NEW_CONCERT,
            title=concert.name,
            body=new_concert_body(artist_by_user[user.id], concert),
            scheduled_at=scheduled,
        ))

    logger.info(f"신규 공연 알림 생성: {concert.name} ({len(users)}명)")


# 동시에 발송할 FCM 요청 수 상한 (스레드풀 기본 워커 수를 넘지 않도록 제한)
_FCM_SEND_CONCURRENCY = 10

# 예약 시각에서 이만큼 지나면 푸시는 포기하고 알림함에만 남김 - 일시 오류의 무한 재시도와
# 서버 다운 뒤 한참 늦은 "오늘 공연 날이에요" 푸시를 막음
_PUSH_RETRY_WINDOW = timedelta(hours=1)


# 세마포어로 동시성 제한하며 FCM 발송
async def _send_fcm_limited(
    loop: asyncio.AbstractEventLoop, semaphore: asyncio.Semaphore, token: str, title: str, body: str
) -> str:
    async with semaphore:
        return await loop.run_in_executor(None, _send_fcm, token, title, body)


# 미발송 알림 처리 및 FCM 발송 (스케줄러 호출용). 알림함은 is_sent=True만 보여주므로 토큰 없는
# 유저(푸시 권한 거부, iOS 등)나 재시도 기한이 지난 알림도 푸시 없이 발송 완료로 처리해 알림함엔 남김
async def process_pending_notifications(db: AsyncSession) -> None:
    now = datetime.now(timezone.utc)

    result = await db.execute(
        select(Notification, User.fcm_token)
        .join(User, Notification.user_id == User.id)
        .where(
            Notification.is_sent == False,  # noqa: E712
            Notification.scheduled_at <= now,
        )
    )
    rows = result.all()
    if not rows:
        return

    push_rows = []
    for notif, fcm_token in rows:
        if fcm_token and now - notif.scheduled_at <= _PUSH_RETRY_WINDOW:
            push_rows.append((notif, fcm_token))
        else:
            notif.is_sent = True

    # 알림 발송이 특정 시각(예: 매일 09시)에 몰리므로 순차 발송 대신 동시성 제한을 두고 병렬 발송
    loop = asyncio.get_running_loop()
    semaphore = asyncio.Semaphore(_FCM_SEND_CONCURRENCY)
    results = await asyncio.gather(
        *(_send_fcm_limited(loop, semaphore, fcm_token, notif.title, notif.body) for notif, fcm_token in push_rows)
    )
    invalid_tokens: set[str] = set()
    for (notif, fcm_token), outcome in zip(push_rows, results):
        if outcome == _FCM_INVALID_TOKEN:
            invalid_tokens.add(fcm_token)
        if outcome != _FCM_FAILED:
            notif.is_sent = True

    # 만료 토큰은 지워서 매 틱 재발송을 막음 (앱이 켜질 때마다 새 토큰을 다시 등록함). 그 사이
    # 새 토큰이 등록됐으면 덮어쓰지 않도록 토큰 값이 그대로인 행만 지움
    if invalid_tokens:
        await db.execute(
            update(User).where(User.fcm_token.in_(invalid_tokens)).values(fcm_token=None)
        )

    await db.commit()
