from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.user import User
from app.schemas.recommendation import ArtistRecommendationResponse
from app.services.recommendation import get_artist_recommendations

router = APIRouter()


# 아티스트 추천 목록 조회 (팔로우/관람 이력 기반, 매 요청마다 실시간 계산)
@router.get("/artists", response_model=ArtistRecommendationResponse)
async def get_artist_recommendations_endpoint(
    limit: int = Query(30, le=100),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    recommendations = await get_artist_recommendations(db, current_user.id, limit=limit)
    return ArtistRecommendationResponse(recommendations=recommendations)
