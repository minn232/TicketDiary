import asyncio
import logging
from uuid import UUID
from datetime import datetime, timedelta, timezone

from fastapi import HTTPException
from sqlalchemy import delete, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.models.concert import Concert
from app.models.notification import Notification, NotificationType
from app.models.social import ConcertFollow
from app.models.user import User

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
async def get_notifications(db: AsyncSession, user_id: UUID) -> list[Notification]:
    result = await db.execute(
        select(Notification)
        .where(Notification.user_id == user_id, Notification.is_sent == True)  # noqa: E712
        .order_by(Notification.scheduled_at.desc())
    )
    return list(result.scalars().all())


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
            body="티켓팅 날이에요! 지금 바로 예매하세요.",
            scheduled_at=scheduled,
        ))

    await db.commit()
    logger.info(f"티켓팅 알림 생성: {concert.name} ({len(rows)}명)")


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
            body=f"{artist_by_user[user.id]}의 새 공연이 등록됐어요!",
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
