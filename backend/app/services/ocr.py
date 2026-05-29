import io
import os
import base64
import tempfile

import httpx
from PIL import Image
from fastapi import HTTPException

from app.core.config import settings

_VISION_URL = "https://vision.googleapis.com/v1/images:annotate"


# Magic bytes 우선, 그 다음 content_type으로 이미지 포맷 감지
def _detect_format(image_bytes: bytes, content_type: str) -> str:
    if len(image_bytes) >= 3 and image_bytes[:3] == b"\xff\xd8\xff":
        return "jpeg"
    if len(image_bytes) >= 4 and image_bytes[:4] == b"\x89PNG":
        return "png"
    # HEIC/HEIF: ftyp box가 offset 4에 위치
    if len(image_bytes) >= 12 and image_bytes[4:8] == b"ftyp":
        return "heic"
    # TIFF 매직 바이트 (리틀엔디언 / 빅엔디언) — DNG도 TIFF 기반
    if len(image_bytes) >= 4 and image_bytes[:4] in (b"II*\x00", b"MM\x00*"):
        return "dng" if "dng" in content_type.lower() else "tiff"
    if len(image_bytes) >= 12 and image_bytes[:4] == b"RIFF" and image_bytes[8:12] == b"WEBP":
        return "webp"
    if len(image_bytes) >= 2 and image_bytes[:2] == b"BM":
        return "bmp"

    # 매직 바이트로 감지 실패 시 content_type 폴백
    ct = content_type.lower()
    if "heic" in ct or "heif" in ct:
        return "heic"
    if "dng" in ct:
        return "dng"
    if "jpeg" in ct or "jpg" in ct:
        return "jpeg"
    if "png" in ct:
        return "png"
    if "webp" in ct:
        return "webp"
    if "tiff" in ct:
        return "tiff"
    if "bmp" in ct:
        return "bmp"
    return "unknown"


# 여러 포맷 JPEG 변환
def _to_jpeg(image_bytes: bytes, content_type: str) -> bytes:
    fmt = _detect_format(image_bytes, content_type)

    if fmt == "jpeg":
        return image_bytes

    if fmt == "heic":
        try:
            import pillow_heif
            pillow_heif.register_heif_opener()
        except ImportError:
            raise HTTPException(
                status_code=422,
                detail="HEIC/HEIF 이미지 처리를 위해 pillow-heif 패키지가 필요합니다.",
            )
        img = Image.open(io.BytesIO(image_bytes))

    elif fmt == "dng":
        try:
            import rawpy
            import numpy as np  # rawpy는 numpy 배열로 RAW 데이터를 반환
        except ImportError:
            raise HTTPException(
                status_code=422,
                detail="DNG/RAW 이미지 처리를 위해 rawpy 패키지가 필요합니다.",
            )
        with tempfile.NamedTemporaryFile(suffix=".dng", delete=False) as tmp:
            tmp.write(image_bytes)
            tmp_path = tmp.name
        try:
            with rawpy.imread(tmp_path) as raw:
                rgb = raw.postprocess()
            img = Image.fromarray(rgb)
        finally:
            os.unlink(tmp_path)

    else:
        # PNG, TIFF, WebP, BMP, GIF 등 Pillow가 지원하는 나머지 포맷
        img = Image.open(io.BytesIO(image_bytes))

    # JPEG는 알파 채널 미지원 -> RGB 변환
    if img.mode != "RGB":
        img = img.convert("RGB")

    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=90)
    return buf.getvalue()


# Google Vision API로 이미지에서 텍스트 추출 (fullTextAnnotation.text만 반환)
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

    # JSON 응답에서 fullTextAnnotation.text 필드 추출 (텍스트만 반환)
    annotation = response.json().get("responses", [{}])[0]
    full_text = annotation.get("fullTextAnnotation", {}).get("text", "")

    if not full_text:
        raise HTTPException(status_code=422, detail="이미지에서 텍스트를 인식할 수 없습니다.")

    return full_text


# LLM 엔드포인트로 OCR 순수 텍스트를 전달해 티켓 필드 파싱
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


# 이미지 -> JPEG 변환 -> OCR -> LLM 순으로 티켓 정보 추출
async def extract_ticket_info(image_bytes: bytes, content_type: str) -> dict:
    jpeg_bytes = _to_jpeg(image_bytes, content_type)
    raw_text = await _extract_raw_text(jpeg_bytes)
    return await _parse_ticket_fields(raw_text)
