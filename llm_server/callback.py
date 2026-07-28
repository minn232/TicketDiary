import logging

import httpx

from config import settings

logger = logging.getLogger(__name__)


async def _post(path: str, body: dict) -> None:
    url = f"{settings.BACKEND_BASE_URL}{path}"
    async with httpx.AsyncClient(timeout=settings.CALLBACK_TIMEOUT_SECONDS) as client:
        response = await client.post(
            url,
            json=body,
            headers={"Authorization": f"Bearer {settings.LLM_EXTRACT_API_KEY}"},
        )
        response.raise_for_status()


async def send_crawl_result(concert_id: str, body: dict) -> None:
    await _post(f"/concerts/{concert_id}/crawl-result", body)


async def send_artist_result(concert_id: str, body: dict) -> None:
    await _post(f"/concerts/{concert_id}/artist-result", body)


async def send_diary_result(ticket_id: str, body: dict) -> None:
    await _post(f"/tickets/{ticket_id}/diary-result", body)
