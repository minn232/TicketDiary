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


# body: 성공이면 {emotion, title, body}, 실패면 {emotion, error} - emotion은 받은 감상 글 그대로(백엔드가
# 그 사이 메모가 바뀌었는지 비교해 옛 결과를 버림)
async def send_blog_draft_result(ticket_id: str, body: dict) -> None:
    await _post(f"/tickets/{ticket_id}/blog-draft-result", body)
