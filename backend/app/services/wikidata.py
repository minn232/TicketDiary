import asyncio
import logging
from urllib.parse import quote

import httpx

from app.core.config import settings

logger = logging.getLogger(__name__)

# Wikidata는 MusicBrainz처럼 명시적인 초당 요청 제한 정책은 없지만, 예의상 비슷한 수준으로
# 스로틀 - musicbrainz.py의 _throttle/_get_with_retry와 동일한 패턴
_MIN_REQUEST_INTERVAL = 1.0
_MAX_RETRIES = 2
_RETRY_BACKOFF_SECONDS = 2.0

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


# Wikidata 항목(QID) 전체를 가져온다 - fetch_korean_label/fetch_artist_image_url이 공유하는
# 스로틀+재시도 헬퍼. 항목이 없거나 조회 실패하면 None
async def _fetch_entity(qid: str, client: httpx.AsyncClient) -> dict | None:
    last_error: Exception | None = None
    for attempt in range(_MAX_RETRIES + 1):
        await _throttle()
        try:
            response = await client.get(
                f"{settings.WIKIDATA_BASE_URL}/wiki/Special:EntityData/{qid}.json",
                headers={"User-Agent": settings.MUSICBRAINZ_USER_AGENT},
            )
            if response.status_code == 200:
                data = response.json()
                return data.get("entities", {}).get(qid, {})
            last_error = Exception(f"HTTP {response.status_code}")
        except httpx.HTTPError as e:
            last_error = e

        if attempt < _MAX_RETRIES:
            await asyncio.sleep(_RETRY_BACKOFF_SECONDS)

    logger.warning(f"Wikidata 항목 조회 실패 (qid={qid}): {last_error}")
    return None


# Wikidata 항목(QID)의 한글 label을 가져온다. 항목이 없거나 한글 label이 없으면 None -
# musicbrainz.py의 User-Agent 정책(연락처 명시)을 그대로 재사용
async def fetch_korean_label(qid: str, client: httpx.AsyncClient | None = None) -> str | None:
    async def _run(c: httpx.AsyncClient) -> str | None:
        entity = await _fetch_entity(qid, c)
        if entity is None:
            return None
        return entity.get("labels", {}).get("ko", {}).get("value")

    if client is not None:
        return await _run(client)
    async with httpx.AsyncClient(timeout=10.0) as c:
        return await _run(c)


# Wikidata 항목(QID)의 대표 이미지(P18, 위키미디어 커먼즈 파일명)를 실제 표시 가능한 URL로
# 변환해 가져온다. Special:FilePath는 파일명만 있으면 실제 파일로 리다이렉트해주는 커먼즈 표준
# 경로라 별도 다운로드 없이 <img src>에 바로 씀. 항목/이미지가 없으면 None
async def fetch_artist_image_url(qid: str, client: httpx.AsyncClient | None = None) -> str | None:
    async def _run(c: httpx.AsyncClient) -> str | None:
        entity = await _fetch_entity(qid, c)
        if entity is None:
            return None
        claims = entity.get("claims", {}).get("P18")
        if not claims:
            return None
        filename = claims[0].get("mainsnak", {}).get("datavalue", {}).get("value")
        if not filename:
            return None
        return f"https://commons.wikimedia.org/wiki/Special:FilePath/{quote(filename)}?width=400"

    if client is not None:
        return await _run(client)
    async with httpx.AsyncClient(timeout=10.0) as c:
        return await _run(c)
