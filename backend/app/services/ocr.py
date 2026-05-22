import base64
import httpx
from fastapi import HTTPException
from app.core.config import settings

_VISION_URL = "https://vision.googleapis.com/v1/images:annotate"


# Google Vision API로 이미지에서 텍스트 추출
async def _extract_raw_text(image_bytes: bytes) -> str:
    payload = {
        "requests": [
            {
                "image": {"content": base64.b64encode(image_bytes).decode()},
                "features": [{"type": "DOCUMENT_TEXT_DETECTION"}],
            }
        ]
    }

    async with httpx.AsyncClient(timeout=15.0) as client:
        response = await client.post(
            _VISION_URL,
            params={"key": settings.GOOGLE_VISION_API_KEY},
            json=payload,
        )

    if response.status_code != 200:
        raise HTTPException(status_code=502, detail="Google Vision API 호출에 실패했습니다.")

    annotation = response.json().get("responses", [{}])[0]
    full_text = annotation.get("fullTextAnnotation", {}).get("text", "")

    if not full_text:
        raise HTTPException(status_code=422, detail="이미지에서 텍스트를 인식할 수 없습니다.")

    return full_text


# LLM 팀 엔드포인트로 OCR 텍스트에서 티켓 정보 파싱
async def _parse_ticket_fields(raw_text: str) -> dict:
    async with httpx.AsyncClient(timeout=30.0) as client:
        response = await client.post(
            settings.LLM_EXTRACT_URL,
            headers={"Authorization": f"Bearer {settings.LLM_EXTRACT_API_KEY}"},
            json={"text": raw_text},
        )

    if response.status_code != 200:
        raise HTTPException(status_code=502, detail="LLM 서비스 호출에 실패했습니다.")

    data = response.json()
    return {
        "title":         data.get("title"),
        "date":          data.get("date"),
        "time":          data.get("time"),
        "shipping_date": data.get("shipping_date"),
        "location":      data.get("location"),
        "seat":          data.get("seat"),
        "platform":      data.get("platform"),
        "price":         data.get("price"),
        "artist":        data.get("artist") or [],
        "event_type":    data.get("event_type"),
    }


# 이미지 -> OCR -> LLM 순으로 티켓 정보 추출
async def extract_ticket_info(image_bytes: bytes, content_type: str) -> dict:
    raw_text = await _extract_raw_text(image_bytes)
    return await _parse_ticket_fields(raw_text)
