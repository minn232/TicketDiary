import asyncio
import io
import os
import re
import base64
import tempfile

import httpx
from PIL import Image
from fastapi import HTTPException

from app.core.config import settings

_VISION_URL = "https://vision.googleapis.com/v1/images:annotate"

# YYYY.MM.DD / YYYY년 N월 N일 등 날짜 패턴
_DATE_RE = re.compile(
    r"(\d{4})\s*[.\-/]\s*(\d{1,2})\s*[.\-/]\s*(\d{1,2})"
    r"|(\d{4})년\s*(\d{1,2})월\s*(\d{1,2})일"
)

# 오후/오전 N시, 오후/오전 H:MM, HH:MM 시간 패턴
_TIME_RE = re.compile(
    r"오후\s*(\d{1,2})시(?:\s*(\d{2})분)?"      # 그룹 1,2: 오후 N시 (분)
    r"|오전\s*(\d{1,2})시(?:\s*(\d{2})분)?"      # 그룹 3,4: 오전 N시 (분)
    r"|오후\s*(\d{1,2}):(\d{2})"                 # 그룹 5,6: 오후 H:MM
    r"|오전\s*(\d{1,2}):(\d{2})"                 # 그룹 7,8: 오전 H:MM
    r"|(\d{1,2}):(\d{2})"                        # 그룹 9,10: HH:MM
)

# N,NNN원 가격 패턴
_PRICE_RE = re.compile(r"([\d,]{4,})\s*원")

# 좌석 등급·구역·열·번 패턴
_SEAT_RE = re.compile(
    r"([A-Z가-힣]{1,5}석)"
    r"(?:\s*[A-Za-z0-9가-힣]+\s*구역)?"
    r"(?:\s*\d+\s*열)?"
    r"(?:\s*\d+\s*번)?"
)

# 플랫폼 키워드 → 정규화 이름
_PLATFORMS = [
    ("인터파크", "INTERPARK"),
    ("interpark", "INTERPARK"),
    ("yes24", "YES24"),
    ("티켓링크", "티켓링크"),
    ("멜론티켓", "멜론티켓"),
    ("멜론 티켓", "멜론티켓"),
    ("ticket.melon.com", "멜론티켓"),
    ("melon", "멜론티켓"),
    ("nol ticket", "NOL ticket"),
    ("nol 티켓", "NOL ticket"),
    ("네이버예약", "네이버 예약"),
    ("네이버 예약", "네이버 예약"),
]

_FESTIVAL_KEYWORDS = ["festival", "fest", "페스티벌", "페스", "뮤직페스"]

# title 후보에서 제외할 줄 시작 패턴
_LABEL_SKIP = re.compile(
    r"^(장소|좌석|가격|날짜|시간|발송|배송|출고"
    r"|인터파크|yes24|티켓링크|멜론|네이버"
    r"|입장번호|일시|예매|예약|주최|주관|문의)",
    re.IGNORECASE,
)


# Magic bytes 우선, 그 다음 content_type으로 이미지 포맷 감지
def _detect_format(image_bytes: bytes, content_type: str) -> str:
    if len(image_bytes) >= 3 and image_bytes[:3] == b"\xff\xd8\xff":
        return "jpeg"
    if len(image_bytes) >= 4 and image_bytes[:4] == b"\x89PNG":
        return "png"
    if len(image_bytes) >= 12 and image_bytes[4:8] == b"ftyp":
        return "heic"
    if len(image_bytes) >= 4 and image_bytes[:4] in (b"II*\x00", b"MM\x00*"):
        return "dng" if "dng" in content_type.lower() else "tiff"
    if len(image_bytes) >= 12 and image_bytes[:4] == b"RIFF" and image_bytes[8:12] == b"WEBP":
        return "webp"
    if len(image_bytes) >= 2 and image_bytes[:2] == b"BM":
        return "bmp"

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
        img = Image.open(io.BytesIO(image_bytes))

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

    annotation = response.json().get("responses", [{}])[0]
    full_text = annotation.get("fullTextAnnotation", {}).get("text", "")

    if not full_text:
        raise HTTPException(status_code=422, detail="이미지에서 텍스트를 인식할 수 없습니다.")

    return full_text


# 날짜 그룹 (y, m, d) → "YYYY-MM-DD" 변환 (범위 외 None)
def _parse_date(year: str, month: str, day: str) -> str | None:
    y, mo, d = int(year), int(month), int(day)
    if 2000 <= y <= 2100 and 1 <= mo <= 12 and 1 <= d <= 31:
        return f"{y:04d}-{mo:02d}-{d:02d}"
    return None


# label_re 이후 window 글자 안에서 날짜 추출
def _find_date_near(text: str, label_re: str, window: int = 60) -> str | None:
    for m in re.finditer(label_re, text, re.IGNORECASE):
        snippet = text[m.start(): m.start() + window]
        dm = _DATE_RE.search(snippet)
        if dm:
            if dm.group(1):
                return _parse_date(dm.group(1), dm.group(2), dm.group(3))
            return _parse_date(dm.group(4), dm.group(5), dm.group(6))
    return None


# label_re 첫 등장 위치 반환 (없으면 None)
def _label_pos(text: str, label_re: str) -> int | None:
    m = re.search(label_re, text, re.IGNORECASE)
    return m.start() if m else None


# 공연명 추출 (레이블 우선 → 첫 번째 유효 줄 폴백)
def _extract_title(text: str) -> str | None:
    m = re.search(r"(?:공연명|행사명|제목)\s*[:：]\s*(.+)", text)
    if m:
        return m.group(1).strip()

    for line in text.splitlines():
        line = line.strip()
        if not line or len(line) < 3 or len(line) > 80:
            continue
        if _DATE_RE.match(line):
            continue
        if _PRICE_RE.match(line):
            continue
        if _LABEL_SKIP.match(line):
            continue
        if re.match(r"^\d", line):
            continue
        return line

    return None


# 공연 날짜 추출 (레이블 우선 → 발송일 이전의 첫 날짜 폴백)
def _extract_concert_date(text: str) -> str | None:
    # (?<!예매)일시: 예매일시를 공연일로 오인하지 않도록 negative lookbehind
    date = _find_date_near(text, r"공연일시?|공연\s*날짜|날짜|(?<!예매)일시")
    if date:
        return date

    ship_pos = _label_pos(text, r"발송|배송|출고")
    for m in _DATE_RE.finditer(text):
        if ship_pos is not None and m.start() >= ship_pos:
            continue
        if m.group(1):
            return _parse_date(m.group(1), m.group(2), m.group(3))
        return _parse_date(m.group(4), m.group(5), m.group(6))
    return None


# 발송 날짜 추출
def _extract_shipping_date(text: str) -> str | None:
    return _find_date_near(text, r"발송\s*예정일?|발송일|배송\s*예정일?|배송일|출고\s*예정일?|출고일")


# 공연 시간 추출 (오후/오전/HH:MM → "HH:MM")
def _extract_time(text: str) -> str | None:
    m = _TIME_RE.search(text)
    if not m:
        return None
    if m.group(1):   # 오후 N시
        h = (int(m.group(1)) % 12) + 12
        mi = int(m.group(2) or 0)
        return f"{h:02d}:{mi:02d}"
    if m.group(3):   # 오전 N시
        h = int(m.group(3))
        mi = int(m.group(4) or 0)
        return f"{h:02d}:{mi:02d}"
    if m.group(5):   # 오후 H:MM
        return f"{(int(m.group(5)) % 12) + 12:02d}:{m.group(6)}"
    if m.group(7):   # 오전 H:MM
        return f"{int(m.group(7)):02d}:{m.group(8)}"
    if m.group(9):   # HH:MM
        return f"{int(m.group(9)):02d}:{m.group(10)}"
    return None


# 공연장 추출 (레이블 우선 → 공연장 키워드 폴백)
def _extract_location(text: str) -> str | None:
    m = re.search(r"(?:장소|공연장소?|공연장)\s*[:：]\s*(.+)", text)
    if m:
        return m.group(1).strip()

    venue_re = re.compile(
        r"[가-힣A-Za-z0-9]+\s*(?:경기장|체육관|아레나|홀|Hall|Arena|Stadium|DOME|돔|센터|극장|공연장)",
        re.IGNORECASE,
    )
    vm = venue_re.search(text)
    return vm.group(0).strip() if vm else None


# 좌석 정보 추출 (레이블 우선 → 석 패턴 폴백)
def _extract_seat(text: str) -> str | None:
    m = re.search(r"(?:좌석|석|SEAT)\s*[:：]\s*(.+)", text, re.IGNORECASE)
    if m:
        return m.group(1).strip()

    sm = _SEAT_RE.search(text)
    return sm.group(0).strip() if sm else None


# 티켓팅 플랫폼 추출
def _extract_platform(text: str) -> str | None:
    lower = text.lower()
    for keyword, normalized in _PLATFORMS:
        if keyword.lower() in lower:
            return normalized
    return None


# 티켓 가격 추출 (1,000원 미만 노이즈 제거 후 첫 번째 값)
def _extract_price(text: str) -> int | None:
    candidates = []
    for m in _PRICE_RE.finditer(text):
        raw = m.group(1).replace(",", "")
        if raw.isdigit():
            val = int(raw)
            if val >= 1000:
                candidates.append(val)
    return candidates[0] if candidates else None


# 단독 공연 / 페스티벌 분류
def _classify_event_type(text: str) -> str:
    lower = text.lower()
    if any(kw in lower for kw in _FESTIVAL_KEYWORDS):
        return "FESTIVAL"
    return "SOLO"


# OCR 순수 텍스트에서 티켓 필드 로컬 파싱
def _parse_ticket_fields(raw_text: str) -> dict:
    return {
        "title":         _extract_title(raw_text),
        "date":          _extract_concert_date(raw_text),
        "time":          _extract_time(raw_text),
        "shipping_date": _extract_shipping_date(raw_text),
        "location":      _extract_location(raw_text),
        "seat":          _extract_seat(raw_text),
        "platform":      _extract_platform(raw_text),
        "price":         _extract_price(raw_text),
        "event_type":    _classify_event_type(raw_text),
    }


# 이미지 -> JPEG 변환 -> Vision OCR -> 로컬 파싱
async def extract_ticket_info(image_bytes: bytes, content_type: str) -> dict:
    loop = asyncio.get_running_loop()
    jpeg_bytes = await loop.run_in_executor(None, _to_jpeg, image_bytes, content_type)
    raw_text = await _extract_raw_text(jpeg_bytes)
    return _parse_ticket_fields(raw_text)
