import logging

import httpx
from fastapi import HTTPException

from app.core.config import settings
from app.models.concert import Concert

logger = logging.getLogger(__name__)


# 유저의 한줄평 + 공연 정보를 VLM팀에 보내 일기 형식의 장문 텍스트로 가공해 받아옴 (동기 호출)
async def generate_diary(review: str, concert: Concert | None) -> str:
    if not settings.LLM_DIARY_URL:
        raise HTTPException(status_code=503, detail="일기 생성 기능이 아직 설정되지 않았습니다.")

    payload = {
        "review": review,
        "concert_name": concert.name if concert else None,
        "artist_name": concert.artist_name if concert else [],
        "venue": concert.venue if concert else None,
        "concert_date": concert.start_date.date().isoformat() if concert else None,
    }

    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(
                settings.LLM_DIARY_URL,
                json=payload,
                headers={"Authorization": f"Bearer {settings.LLM_EXTRACT_API_KEY}"},
            )
    except httpx.HTTPError as e:
        logger.error(f"VLM팀 일기 생성 요청 실패: {e}")
        raise HTTPException(status_code=502, detail="일기 생성 요청에 실패했습니다.")

    if response.status_code != 200:
        logger.error(f"VLM팀 일기 생성 응답 오류: {response.status_code}")
        raise HTTPException(status_code=502, detail="일기 생성에 실패했습니다.")

    diary_text = (response.json().get("diary") or "").strip()
    if not diary_text:
        raise HTTPException(status_code=502, detail="일기 생성 결과가 비어있습니다.")
    return diary_text
