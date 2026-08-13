import asyncio
import logging
from uuid import UUID
from datetime import datetime, timedelta, timezone

from fastapi import HTTPException
from sqlalchemy import delete, select
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


# FCM 푸시 발송
def _send_fcm(token: str, title: str, body: str) -> bool:
    try:
        _init_firebase()
        from firebase_admin import messaging
        message = messaging.Message(
            notification=messaging.Notification(title=title, body=body),
            token=token,
        )
        messaging.send(message)
        return True
    except Exception as e:
        logger.error(f"FCM 발송 실패: {e}")
        return False


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


# 팔로우한 아티스트의 신규 공연에 대해 NEW_CONCERT 알림 생성
# (KOPIS 일별 배치가 "진짜 신규" 공연을 발견했을 때만 호출 - 이미 알던 공연에 아티스트 정보가
# 뒤늦게 채워지는 경우나 검색/상세조회 같은 온디맨드 경로에서는 호출하지 않음. 그래야 알림이
# "오늘 새로 뜬 공연"에 대해서만 가고, 무관한 유저의 조회 행위로 뜻하지 않게 발송되지 않음)
# matched는 kopis.py에서 이미 계산해둔 (팔로워 user_id, 매칭된 아티스트명) 목록을 그대로 받음
# (뉴스피드용으로 이미 아티스트 매칭을 한 번 계산해뒀으므로 여기서 다시 계산하지 않음)
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


# 세마포어로 동시성 제한하며 FCM 발송
async def _send_fcm_limited(
    loop: asyncio.AbstractEventLoop, semaphore: asyncio.Semaphore, token: str, title: str, body: str
) -> bool:
    async with semaphore:
        return await loop.run_in_executor(None, _send_fcm, token, title, body)


# 미발송 알림 처리 및 FCM 발송 (스케줄러 호출용)
async def process_pending_notifications(db: AsyncSession) -> None:
    # 현재 시각 기준으로 발송되지 않은 알림 조회
    now = datetime.now(timezone.utc)

    result = await db.execute(
        select(Notification, User.fcm_token)
        .join(User, Notification.user_id == User.id)
        .where(
            Notification.is_sent == False,  # noqa: E712
            Notification.scheduled_at <= now,
            User.fcm_token.isnot(None),
        )
    )
    rows = result.all()
    if not rows:
        return

    # 알림 발송이 특정 시각(예: 매일 09시)에 몰리므로 순차 발송 대신 동시성 제한을 두고 병렬 발송
    loop = asyncio.get_running_loop()
    semaphore = asyncio.Semaphore(_FCM_SEND_CONCURRENCY)
    results = await asyncio.gather(
        *(_send_fcm_limited(loop, semaphore, fcm_token, notif.title, notif.body) for notif, fcm_token in rows)
    )
    for (notif, _), success in zip(rows, results):
        if success:
            notif.is_sent = True

    await db.commit()
