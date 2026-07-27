from uuid import UUID

from fastapi import APIRouter, BackgroundTasks, Depends, Query
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
from app.services.crawler import crawl_and_save

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
# 찜 목록의 공연들은 아직 아무도 티켓을 등록하지 않았을 수 있어 티켓팅 오픈일이 영영 안 채워질
# 수 있으므로, 여기서도 크롤링을 트리거함(ticketing_site 없이 concert.ticketing_links만으로 시도).
# 이미 크롤링된 공연은 crawl_and_save가 자체적으로 스킵하므로 매번 전체 목록에 걸어도 무해함
@router.patch("/concerts", response_model=ConcertFollowResponse)
async def update_concert_follow(
    body: ConcertFollowUpdate,
    background_tasks: BackgroundTasks,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await social_service.update_concert_follow(db, current_user.id, body.concerts)
    for entry in body.concerts:
        background_tasks.add_task(crawl_and_save, entry.concert_id)
    return result


# 뉴스 피드 조회 (limit/offset은 선택 - 생략하면 기본 상한(200건) 적용)
@router.get("/feed", response_model=list[NewsFeedResponse])
async def list_news_feed(
    limit: int = Query(200, ge=1, le=200),
    offset: int = Query(0, ge=0),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await social_service.get_news_feed(db, current_user.id, limit=limit, offset=offset)


# 뉴스 피드 읽음 처리
@router.patch("/feed/{feed_id}/read", response_model=NewsFeedResponse)
async def read_news_feed(
    feed_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await social_service.mark_feed_read(db, current_user.id, feed_id)
