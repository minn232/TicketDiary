from uuid import UUID

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.social import ArtistFollow, ConcertFollow, NewsFeed
from app.schemas.social import ArtistEntry, ConcertEntry


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


# 선호 아티스트 수정 (전체 교체)
async def update_artist_follow(
    db: AsyncSession, user_id: UUID, artists: list[ArtistEntry]
) -> ArtistFollow:
    row = await get_or_create_artist_follow(db, user_id)
    row.artists = [a.model_dump(mode="json") for a in artists]
    await db.commit()
    await db.refresh(row)
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
async def update_concert_follow(
    db: AsyncSession, user_id: UUID, concerts: list[ConcertEntry]
) -> ConcertFollow:
    row = await get_or_create_concert_follow(db, user_id)
    row.concerts = [c.model_dump(mode="json") for c in concerts]
    await db.commit()
    await db.refresh(row)
    return row


# 뉴스 피드 목록 조회 (안 읽은 항목 먼저)
async def get_news_feed(db: AsyncSession, user_id: UUID) -> list[NewsFeed]:
    result = await db.execute(
        select(NewsFeed)
        .options(selectinload(NewsFeed.concert))
        .where(NewsFeed.user_id == user_id)
        .order_by(NewsFeed.is_read.asc(), NewsFeed.id.desc())
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
