import asyncio
import logging

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


# Wikidata 항목(QID)의 한글 label을 가져온다. 항목이 없거나 한글 label이 없으면 None -
# musicbrainz.py의 User-Agent 정책(연락처 명시)을 그대로 재사용
async def fetch_korean_label(qid: str, client: httpx.AsyncClient | None = None) -> str | None:
    async def _fetch(c: httpx.AsyncClient) -> str | None:
        last_error: Exception | None = None
        for attempt in range(_MAX_RETRIES + 1):
            await _throttle()
            try:
                response = await c.get(
                    f"{settings.WIKIDATA_BASE_URL}/wiki/Special:EntityData/{qid}.json",
                    headers={"User-Agent": settings.MUSICBRAINZ_USER_AGENT},
                )
                if response.status_code == 200:
                    data = response.json()
                    entity = data.get("entities", {}).get(qid, {})
                    label = entity.get("labels", {}).get("ko", {}).get("value")
                    return label
                last_error = Exception(f"HTTP {response.status_code}")
            except httpx.HTTPError as e:
                last_error = e

            if attempt < _MAX_RETRIES:
                await asyncio.sleep(_RETRY_BACKOFF_SECONDS)

        logger.warning(f"Wikidata 한글 label 조회 실패 (qid={qid}): {last_error}")
        return None

    if client is not None:
        return await _fetch(client)
    async with httpx.AsyncClient(timeout=10.0) as c:
        return await _fetch(c)
