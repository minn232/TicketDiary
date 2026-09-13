from fastapi import APIRouter, Depends, Query

from app.core.deps import get_current_user
from app.models.user import User
from app.schemas.music_link import MusicLinkResolveResponse
from app.services.music_resolve import (
    resolve_apple_music_track,
    resolve_spotify_track,
    resolve_youtube_music_video,
    resolve_youtube_video,
)

router = APIRouter()

_RESOLVERS = {
    "spotify": resolve_spotify_track,
    "youtube": resolve_youtube_video,
    "youtube_music": resolve_youtube_music_video,
    "apple_music": resolve_apple_music_track,
}


# 셋리스트 곡 하나를 서비스별 정확한 링크로 특정 - 못 찾으면 url=null(프론트가 검색화면으로
# 폴백). 모르는 service면 그냥 null(에러 아님 - 프론트가 아는 서비스 값만 보낸다는 전제).
@router.get("/resolve", response_model=MusicLinkResolveResponse)
async def resolve_music_link(
    service: str = Query(...),
    song: str = Query(...),
    artist: str | None = Query(None),
    current_user: User = Depends(get_current_user),
):
    resolver = _RESOLVERS.get(service)
    if resolver is None:
        return MusicLinkResolveResponse(url=None)
    url = await resolver(artist, song)
    return MusicLinkResolveResponse(url=url)
