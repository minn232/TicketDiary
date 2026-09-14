import asyncio
import logging

import httpx

logger = logging.getLogger(__name__)

# oEmbed는 공개 임베드 미리보기용 엔드포인트라 앱 등록/Client Credentials 토큰 없이 누구나
# 호출 가능(정식 Web API 인증은 사진 하나만 필요한 여기서는 불필요, 실측 확인). 문서화된
# 요청 제한은 없지만 예의상 최소 간격만 둠
_OEMBED_URL = "https://open.spotify.com/oembed"
_MIN_REQUEST_INTERVAL = 0.5

_request_lock = asyncio.Lock()
_last_request_at = 0.0


async def _throttle() -> None:
    global _last_request_at
    async with _request_lock:
        loop = asyncio.get_event_loop()
        now = loop.time()
        wait = _last_request_at + _MIN_REQUEST_INTERVAL - now
        if wait > 0:
            await asyncio.sleep(wait)
        _last_request_at = loop.time()


# Spotify 아티스트 페이지 URL(MusicBrainz가 mbid에 걸어둔 것)의 대표 사진을 oEmbed로 가져온다.
# 이름 검색이 아니라 mbid로 이미 확정된 URL을 그대로 쓰는 거라 동명이인 위험이 없음. 실패/
# 이미지 없음은 조용히 None
async def fetch_oembed_thumbnail(spotify_url: str, client: httpx.AsyncClient | None = None) -> str | None:
    async def _fetch(c: httpx.AsyncClient) -> str | None:
        await _throttle()
        try:
            response = await c.get(_OEMBED_URL, params={"url": spotify_url})
        except httpx.HTTPError as e:
            logger.warning(f"Spotify oEmbed 조회 실패 ({spotify_url}): {e}")
            return None

        if response.status_code != 200:
            return None

        try:
            data = response.json()
        except ValueError:
            return None

        return data.get("thumbnail_url")

    if client is not None:
        return await _fetch(client)
    async with httpx.AsyncClient(timeout=10.0) as c:
        return await _fetch(c)
