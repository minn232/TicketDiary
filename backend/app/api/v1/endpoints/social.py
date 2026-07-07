from uuid import UUID

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.user import User
from app.schemas.social import (
    ArtistFollowResponse,
    ArtistFollowUpdate,
    ConcertFollowResponse,
    ConcertFollowUpdate,
    NewsFeedResponse,
)
from app.services import social as social_service

router = APIRouter()


# 선호 아티스트 조회
@router.get("/artists", response_model=ArtistFollowResponse)
async def get_artist_follow(
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await social_service.get_or_create_artist_follow(db, current_user.id)


# 선호 아티스트 수정 (전체 교체)
@router.patch("/artists", response_model=ArtistFollowResponse)
async def update_artist_follow(
    body: ArtistFollowUpdate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await social_service.update_artist_follow(db, current_user.id, body.artists)


# 찜 공연 조회
@router.get("/concerts", response_model=ConcertFollowResponse)
async def get_concert_follow(
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await social_service.get_or_create_concert_follow(db, current_user.id)


# 찜 공연 수정 (전체 교체)
@router.patch("/concerts", response_model=ConcertFollowResponse)
async def update_concert_follow(
    body: ConcertFollowUpdate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await social_service.update_concert_follow(db, current_user.id, body.concerts)


# 뉴스 피드 조회
@router.get("/feed", response_model=list[NewsFeedResponse])
async def list_news_feed(
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await social_service.get_news_feed(db, current_user.id)


# 뉴스 피드 읽음 처리
@router.patch("/feed/{feed_id}/read", response_model=NewsFeedResponse)
async def read_news_feed(
    feed_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await social_service.mark_feed_read(db, current_user.id, feed_id)
