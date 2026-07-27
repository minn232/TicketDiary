import asyncio
import logging

import httpx
from sqlalchemy import delete, select

from app.core.config import settings
from app.core.database import AsyncSessionLocal
from app.models.artist_similarity import ArtistSimilarity
from app.models.concert import Concert

logger = logging.getLogger(__name__)

# Last.fm 요청 간 최소 간격 (레이트리밋 방지)
_REQUEST_INTERVAL = 0.3


# Last.fm artist.getSimilar 호출 (autocorrect로 표기 오차 보정). 실패/결과없음이면 빈 리스트
async def fetch_similar_artists(artist_name: str, limit: int = 30) -> list[tuple[str, float]]:
    if not settings.LASTFM_API_KEY:
        return []

    params = {
        "method": "artist.getSimilar",
        "artist": artist_name,
        "api_key": settings.LASTFM_API_KEY,
        "autocorrect": 1,
        "limit": limit,
        "format": "json",
    }

    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.get(settings.LASTFM_BASE_URL, params=params)
    except httpx.HTTPError as e:
        logger.warning(f"Last.fm 호출 실패 ({artist_name}): {e}")
        return []

    if response.status_code != 200:
        logger.warning(f"Last.fm 응답 오류 ({artist_name}): {response.status_code}")
        return []

    try:
        payload = response.json()
    except ValueError as e:
        logger.warning(f"Last.fm 응답 파싱 실패 ({artist_name}): {e}")
        return []

    artists = payload.get("similarartists", {}).get("artist", [])
    return [(a["name"], float(a.get("match", 0))) for a in artists if a.get("name")]


# 아직 캐싱 안 된 아티스트만 골라 Last.fm에서 유사 아티스트를 가져와 저장
# (한 번 캐싱된 아티스트는 재조회하지 않음 - 유사 아티스트 관계는 자주 바뀌지 않는다고 가정)
async def sync_artist_similarities() -> None:
    async with AsyncSessionLocal() as db:
        concert_result = await db.execute(select(Concert.artist_name).where(Concert.artist_name != []))
        all_names = {
            name.strip()
            for arr in concert_result.scalars().all()
            for name in (arr or [])
            if name and name.strip()
        }

        cached_result = await db.execute(select(ArtistSimilarity.artist_name.distinct()))
        cached_names = set(cached_result.scalars().all())

    pending = sorted(all_names - cached_names)
    if not pending:
        logger.info("Last.fm 신규 캐싱 대상 아티스트 없음")
        return

    logger.info(f"Last.fm 유사 아티스트 캐싱 대상 {len(pending)}건")
    for i, artist_name in enumerate(pending):
        if i > 0:
            await asyncio.sleep(_REQUEST_INTERVAL)

        # 한 아티스트에서 예기치 못한 오류(DB 오류 등)가 나도 이후 아티스트들은 계속 처리
        # (안 그러면 이 아티스트가 pending 목록에서 매번 같은 자리에 있어 뒤쪽이 영구히 밀림)
        try:
            similar = await fetch_similar_artists(artist_name)
            if not similar:
                continue

            async with AsyncSessionLocal() as db:
                await db.execute(delete(ArtistSimilarity).where(ArtistSimilarity.artist_name == artist_name))
                db.add_all(
                    [
                        ArtistSimilarity(artist_name=artist_name, similar_artist_name=name, match_score=score)
                        for name, score in similar
                    ]
                )
                await db.commit()
        except Exception as e:
            logger.warning(f"Last.fm 아티스트 캐싱 실패, 다음으로 계속 ({artist_name}): {e}")
            continue
