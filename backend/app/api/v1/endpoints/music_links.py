import logging
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, Query
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.music_link_cache import MusicLinkCache
from app.models.user import User
from app.schemas.music_link import MusicLinkResolveResponse
from app.services.music_resolve import (
    resolve_apple_music_track,
    resolve_spotify_track,
    resolve_youtube_music_video,
    resolve_youtube_video,
)

logger = logging.getLogger(__name__)

router = APIRouter()

_RESOLVERS = {
    "spotify": resolve_spotify_track,
    "youtube": resolve_youtube_video,
    "youtube_music": resolve_youtube_music_video,
    "apple_music": resolve_apple_music_track,
}

# 찾은 결과는 오래 유지(영상/트랙이 갑자기 사라지는 경우는 드묾), 못 찾은 결과는 짧게
# 재시도 가능하게 - 나중에 정식 발매되거나 업로드될 수 있어서.
_CACHE_TTL_FOUND = timedelta(days=30)
_CACHE_TTL_NOT_FOUND = timedelta(days=3)


async def _get_cached_url(
    db: AsyncSession, service: str, artist: str, song: str
) -> tuple[bool, str | None]:
    """(캐시 적중 여부, 캐시된 url)을 반환. 쿨다운이 지났으면 적중 안 한 것으로 취급."""
    result = await db.execute(
        select(MusicLinkCache).where(
            MusicLinkCache.service == service,
            MusicLinkCache.artist == artist,
            MusicLinkCache.song == song,
        )
    )
    row = result.scalar_one_or_none()
    if row is None:
        return False, None
    ttl = _CACHE_TTL_FOUND if row.resolved_url else _CACHE_TTL_NOT_FOUND
    if datetime.now(timezone.utc) - row.resolved_at > ttl:
        return False, None
    return True, row.resolved_url


# 동시에 같은 조합이 처음 조회되면(두 유저가 같은 순간에 같은 곡을 누르는 등) INSERT가
# 겹쳐 유니크 제약 위반이 날 수 있음 - 캐싱은 실패해도 응답 자체엔 영향 없어야 하므로
# 조용히 무시(다음 조회 때 다시 시도됨).
async def _save_cache(db: AsyncSession, service: str, artist: str, song: str, url: str | None) -> None:
    try:
        result = await db.execute(
            select(MusicLinkCache).where(
                MusicLinkCache.service == service,
                MusicLinkCache.artist == artist,
                MusicLinkCache.song == song,
            )
        )
        row = result.scalar_one_or_none()
        now = datetime.now(timezone.utc)
        if row is None:
            db.add(MusicLinkCache(service=service, artist=artist, song=song, resolved_url=url, resolved_at=now))
        else:
            row.resolved_url = url
            row.resolved_at = now
        await db.commit()
    except IntegrityError:
        await db.rollback()
    except Exception as e:
        await db.rollback()
        logger.warning(f"음악 링크 캐시 저장 실패 (service={service}, artist={artist}, song={song}): {e}")


# 셋리스트 곡 하나를 서비스별 정확한 링크로 특정 - 못 찾으면 url=null(프론트가 검색화면으로
# 폴백). 모르는 service면 그냥 null(에러 아님 - 프론트가 아는 서비스 값만 보낸다는 전제).
# 결과는 DB에 캐싱해서 같은 조합을 매번 실제 API로 재확인하지 않음(유튜브 쿼터 소진 방지).
@router.get("/resolve", response_model=MusicLinkResolveResponse)
async def resolve_music_link(
    service: str = Query(...),
    song: str = Query(...),
    artist: str | None = Query(None),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    resolver = _RESOLVERS.get(service)
    if resolver is None:
        return MusicLinkResolveResponse(url=None)

    normalized_artist = (artist or "").strip()
    hit, cached_url = await _get_cached_url(db, service, normalized_artist, song)
    if hit:
        return MusicLinkResolveResponse(url=cached_url)

    try:
        url = await resolver(artist, song)
    except Exception:
        # music_resolve.py가 API 에러(레이트리밋/네트워크 오류 등)는 그대로 던지도록 돼있음 -
        # "확인해봤는데 정말 없음"과 구분해서 캐싱하지 않고 다음 요청 때 재시도되게 함(실측:
        # 이 구분이 없어서 429가 3일짜리 "못 찾음"으로 캐싱돼 재시도 자체가 막혔던 버그).
        # 경고 로그는 music_resolve.py에서 이미 남김.
        return MusicLinkResolveResponse(url=None)

    await _save_cache(db, service, normalized_artist, song, url)
    return MusicLinkResolveResponse(url=url)
