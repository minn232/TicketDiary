import logging
from datetime import datetime, timedelta, timezone
from uuid import UUID

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.concert import Concert
from app.models.social import ArtistFollow, ConcertFollow, NewsFeed
from app.models.ticket import Ticket
from app.schemas.social import ArtistEntry, ConcertEntry

logger = logging.getLogger(__name__)


# 선호 아티스트 조회 (없으면 생성)
async def get_or_create_artist_follow(db: AsyncSession, user_id: UUID) -> ArtistFollow:
    result = await db.execute(select(ArtistFollow).where(ArtistFollow.user_id == user_id))
    row = result.scalar_one_or_none()
    if row is None:
        row = ArtistFollow(user_id=user_id, artists=[])
        db.add(row)
        await db.commit()
        await db.refresh(row)
    return row


# 새로 팔로우한 아티스트와 매칭되는 기존 DB 공연에 대해 즉시 뉴스피드 생성
# (배치는 자정에만 도니, 팔로우 시점에 이미 존재하는 공연은 바로 반영해줌)
async def _generate_feeds_for_new_follows(
    db: AsyncSession, user_id: UUID, new_artist_names: list[str]
) -> None:
    artist_names_lower = {name.lower() for name in new_artist_names if name}
    if not artist_names_lower:
        return

    now = datetime.now(timezone.utc)
    result = await db.execute(select(Concert).where(Concert.start_date >= now))
    concerts = result.scalars().all()

    matched: list[tuple[Concert, str]] = []
    for concert in concerts:
        for artist in concert.artist_name or []:
            if artist.lower() in artist_names_lower:
                matched.append((concert, artist))
                break

    if not matched:
        return

    concert_ids = [c.id for c, _ in matched]
    existing_result = await db.execute(
        select(NewsFeed.concert_id).where(
            NewsFeed.user_id == user_id,
            NewsFeed.concert_id.in_(concert_ids),
        )
    )
    existing_concert_ids = set(existing_result.scalars().all())

    for concert, artist_name in matched:
        if concert.id not in existing_concert_ids:
            db.add(NewsFeed(user_id=user_id, concert_id=concert.id, artist_name=artist_name))

    await db.commit()


# 선호 아티스트 수정 (전체 교체)
async def update_artist_follow(
    db: AsyncSession, user_id: UUID, artists: list[ArtistEntry]
) -> ArtistFollow:
    row = await get_or_create_artist_follow(db, user_id)

    previous_names_lower = {
        entry.get("artist_name", "").lower()
        for entry in (row.artists or [])
        if entry.get("artist_name")
    }

    row.artists = [a.model_dump(mode="json") for a in artists]
    await db.commit()
    await db.refresh(row)

    new_artist_names = [
        a.artist_name for a in artists if a.artist_name.lower() not in previous_names_lower
    ]
    if new_artist_names:
        await _generate_feeds_for_new_follows(db, user_id, new_artist_names)

    return row


# 찜 공연 조회 (없으면 생성)
async def get_or_create_concert_follow(db: AsyncSession, user_id: UUID) -> ConcertFollow:
    result = await db.execute(select(ConcertFollow).where(ConcertFollow.user_id == user_id))
    row = result.scalar_one_or_none()
    if row is None:
        row = ConcertFollow(user_id=user_id, concerts=[])
        db.add(row)
        await db.commit()
        await db.refresh(row)
    return row


# 찜 공연 수정 (전체 교체)
# 이미 티켓 등록된 공연은 찜 목적(티켓팅 날짜 추적)을 다한 것이므로 제외하고 저장
# (반대 방향은 remove_concert_follow 참고)
async def update_concert_follow(
    db: AsyncSession, user_id: UUID, concerts: list[ConcertEntry]
) -> ConcertFollow:
    row = await get_or_create_concert_follow(db, user_id)

    ticketed_result = await db.execute(
        select(Ticket.concert_id).where(
            Ticket.user_id == user_id,
            Ticket.concert_id.in_([c.concert_id for c in concerts]),
        )
    )
    ticketed_ids = set(ticketed_result.scalars().all())

    row.concerts = [
        c.model_dump(mode="json") for c in concerts if c.concert_id not in ticketed_ids
    ]
    await db.commit()
    await db.refresh(row)
    return row


# 찜 공연은 티켓팅 날짜를 추적하려는 목적이라, 그 공연 티켓을 등록하면 목적을
# 다한 것으로 보고 자동으로 찜 해제(ticket.py의 create_ticket에서 호출). 애초에
# 안 찜한 공연이면 조용히 넘어감. 아티스트 찜은 건드리지 않음(그 아티스트의
# 다음 공연들도 계속 소식 받고 싶은 별개 목적이라 유지).
async def remove_concert_follow(db: AsyncSession, user_id: UUID, concert_id: UUID) -> None:
    result = await db.execute(select(ConcertFollow).where(ConcertFollow.user_id == user_id))
    row = result.scalar_one_or_none()
    if row is None:
        return

    concert_id_str = str(concert_id)
    remaining = [c for c in row.concerts if c.get("concert_id") != concert_id_str]
    if len(remaining) == len(row.concerts):
        return

    row.concerts = remaining
    await db.commit()


# 찜 공연 중 종료된 공연을 매일 배치로 자동 해제 (스케줄러 호출).
# "종료" 기준은 sync_ticket_statuses와 동일(end_date+15h < now). 전체 콘서트
# 대신 찜된 concert_id만 모아 대조해 스캔량을 줄임.
async def cleanup_ended_concert_follows(db: AsyncSession) -> None:
    now = datetime.now(timezone.utc)
    result = await db.execute(select(ConcertFollow))
    rows = result.scalars().all()

    concert_ids: set[UUID] = set()
    for row in rows:
        for entry in row.concerts or []:
            raw_id = entry.get("concert_id")
            if not raw_id:
                continue
            try:
                concert_ids.add(UUID(raw_id))
            except ValueError:
                continue
    if not concert_ids:
        return

    ended_result = await db.execute(
        select(Concert.id).where(
            Concert.id.in_(concert_ids),
            Concert.end_date + timedelta(hours=15) < now,
        )
    )
    ended_ids = {str(cid) for cid in ended_result.scalars().all()}
    if not ended_ids:
        return

    affected_users = 0
    for row in rows:
        remaining = [c for c in row.concerts if c.get("concert_id") not in ended_ids]
        if len(remaining) != len(row.concerts):
            row.concerts = remaining
            affected_users += 1

    if affected_users:
        await db.commit()
        logger.info(f"찜 공연 자동 해제: {affected_users}명, 종료 공연 {len(ended_ids)}건")


# 뉴스 피드 목록 조회 (안 읽은 항목 먼저)
# 유저별 뉴스피드가 무제한으로 쌓이므로 응답이 계속 커지지 않도록 기본 상한을 둠
_DEFAULT_NEWS_FEED_LIMIT = 200


async def get_news_feed(
    db: AsyncSession, user_id: UUID, limit: int = _DEFAULT_NEWS_FEED_LIMIT, offset: int = 0
) -> list[NewsFeed]:
    result = await db.execute(
        select(NewsFeed)
        .options(selectinload(NewsFeed.concert))
        .where(NewsFeed.user_id == user_id)
        .order_by(NewsFeed.is_read.asc(), NewsFeed.created_at.desc())
        .limit(limit)
        .offset(offset)
    )
    return list(result.scalars().all())


# 뉴스 피드 읽음 처리
async def mark_feed_read(db: AsyncSession, user_id: UUID, feed_id: UUID) -> NewsFeed:
    result = await db.execute(
        select(NewsFeed)
        .options(selectinload(NewsFeed.concert))
        .where(NewsFeed.id == feed_id, NewsFeed.user_id == user_id)
    )
    feed = result.scalar_one_or_none()
    if feed is None:
        raise HTTPException(status_code=404, detail="뉴스 피드 항목을 찾을 수 없습니다.")
    feed.is_read = True
    await db.commit()
    await db.refresh(feed)
    return feed
