from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.user import User
from app.schemas.artist import ArtistSearchResponse
from app.services.artist_search import search_artists

router = APIRouter()


# 아티스트 검색(팔로우용, DB 기준) - concerts.py의 /search(KOPIS 실시간, 공연 검색)와는 별개
@router.get("/search", response_model=ArtistSearchResponse)
async def search_artists_endpoint(
    q: str = Query(...),
    limit: int = Query(30, le=100),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    results = await search_artists(db, q, limit=limit)
    return ArtistSearchResponse(results=results)
