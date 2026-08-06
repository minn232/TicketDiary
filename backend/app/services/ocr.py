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
from app.services.text_utils import min_len_ok

_VISION_URL = "https://vision.googleapis.com/v1/images:annotate"

# YYYY.MM.DD / YYYY년 N월 N일 등 날짜 패턴
_DATE_RE = re.compile(
    r"(\d{4})\s*[.\-/]\s*(\d{1,2})\s*[.\-/]\s*(\d{1,2})"
    r"|(\d{4})년\s*(\d{1,2})월\s*(\d{1,2})일"
)

# 일부 모바일 티켓 앱(예: NOL ticket)은 날짜를 한 줄에 이어 쓰지 않고 월/일/연도를
# 큰 숫자로 한 줄씩 세로로 나열함(예: "09" / "20" / "2026"). _DATE_RE는 한 줄 안에
# 구분자로 이어진 형태만 잡으므로 이 레이아웃은 못 잡는다 - _extract_concert_date의
# 최후 폴백으로만 사용(월/일/연도 값 범위는 _parse_date가 검증)
_STACKED_DATE_RE = re.compile(r"(?<!\d)(\d{1,2})\s*\n\s*(\d{1,2})\s*\n\s*(\d{4})(?!\d)")

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

# 좌석 등급·구역·열·번 패턴. 앞에 공백/줄바꿈/구분자가 와야만 매칭 시작 가능하도록 제한
# (그렇지 않으면 "...구역아지정석"처럼 바로 앞 단어의 마지막 글자를 등급명에 끌고 들어와
# "아지정석"처럼 엉뚱하게 잘리는 문제가 생김 - 등급명은 항상 별도 줄/라벨로 인쇄되므로 안전한 제약)
_SEAT_RE = re.compile(
    r"(?:^|(?<=[\s:：,·\-]))([A-Z가-힣]{1,5}석)"
    r"(?:\s*[A-Za-z0-9가-힣]+\s*구역)?"
    r"(?:\s*\d+\s*열)?"
    r"(?:\s*\d+\s*번)?",
    re.MULTILINE,
)

# 예매내역 캡처(라벨-값 격자 UI)의 행 라벨 → 스키마 필드 매핑. 사이트별 사전 없이
# 실샘플(티켓링크/인터파크/멜론티켓/YES24 추정)에서 관찰된 라벨 변형을 하나로 통합
_ROW_LABEL_FIELD = {
    "관람일시": "datetime",
    "관람일": "datetime",
    "일시": "datetime",
    "장소": "location",
    "공연장소": "location",
    "공연장": "location",
    "좌석": "seat",
    "예매채널": "platform",
    "예매경로": "platform",
    "티켓금액": "price",
    "구매금액": "price",
    "가격": "price",
    "금액": "price",
}

# "좌석(1)"처럼 라벨 뒤에 붙는 개수 표기 제거
_ROW_LABEL_SUFFIX_RE = re.compile(r"\s*\(\d+\)\s*$")

# 격자 구조 채택 최소 기준 (라벨 인식 개수). datetime 포함 최소 2개 필드가 매칭돼야
# "예매내역 캡처" 레이아웃으로 판단 - 모바일 티켓처럼 이 격자 자체가 없는 이미지는
# 애초에 라벨 매칭이 거의/전혀 안 되므로 자연스럽게 기존 regex 경로로 폴백됨
_MIN_LAYOUT_FIELD_MATCHES = 2

# 예매내역 캡처의 헤더 영역(격자 시작 전)에서 실제 공연명이 아닌 화면 UI 텍스트를
# 걸러내기 위한 스킵 목록 (네비게이션 타이틀/섹션 헤더/상태뱃지/카테고리 태그)
# 뒤로가기 화살표(< 등)가 OCR로 같이 잡혀서 라벨 앞에 붙는 경우가 있어 선행 기호는 무시
_LAYOUT_TITLE_SKIP = re.compile(
    r"^[<>‹›«»\s]*(상세내역|예매내역|지난\s*관람상세내역|관람상세내역|MY\s*티켓|마이\s*티켓|티켓\s*예매\s*상세내역"
    r"|카테고리|관람내역|예매정보|결제내역|구매\s*내역|티켓\s*수령방법|본인정보"
    r"|배송완료|예매완료|취소완료|주문완료|결제완료|SOLD\s*OUT"
    r"|단독|콘서트|뮤지컬|연극|페스티벌|공연)$",
    re.IGNORECASE,
)

# 헤더 영역 맨 위엔 화면 상태표시줄(시계/배터리/신호)이 찍혀있는 경우가 많은데, OCR이
# 이걸 별도 텍스트 블록으로 인식해서 라벨-값 매칭엔 안 걸리지만 제목 후보에는 그대로
# 남는 문제가 실사용 캡처로 확인됨 - 상태표시줄 특유의 짧은 시각/아이콘 패턴만 제외
# ("2:37" 같은 시계, "l (41)"/"ull 41" 같은 신호·배터리 아이콘 오인식)
_STATUS_BAR_RE = re.compile(r"^\d{1,2}:\d{2}$|^[a-zA-Z]{0,4}\s*\(?\d{1,3}\)?$")

# 진짜 공연명이라면 한글 또는 2자 이상 이어진 영문이 있어야 함 - 햄버거 메뉴/뒤로가기
# 아이콘이 "< =" 같은 기호 조각으로 오인식된 경우를 걸러내기 위함 (실사용 캡처로 확인)
_HAS_REAL_CONTENT_RE = re.compile(r"[가-힣]|[A-Za-z]{2,}")


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
# nol은 단독으로 두면 "Nolan"/"Nolgong" 같은 실제 제목 앞부분과 겹치므로 뒤에 ticket/티켓이
# 붙는 경우(NOL 티켓 플랫폼 라벨)만 매칭하도록 좁힘
_LABEL_SKIP = re.compile(
    r"^(장소|좌석|가격|날짜|시간|발송|배송|출고"
    r"|인터파크|interpark|nol\s*(ticket|티켓)|yes24|티켓링크|멜론|네이버"
    r"|입장번호|일시|예매|예약|주최|주관|문의|전화번호"
    r"|금액|결제|수량|매수|판매일자|구매일자|발권일자)",
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


# Google Vision API 호출, 첫 번째 response 원본(annotation) 반환
# fullTextAnnotation.text(줄글)뿐 아니라 pages/blocks/paragraphs의 좌표(bbox)도
# 같은 응답에 포함돼 있어서, 좌표 기반 레이아웃 파싱을 위해 API를 한 번 더 부르지 않고
# 이 원본 응답을 그대로 재활용한다
async def _call_vision(image_bytes: bytes) -> dict:
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

    return response.json().get("responses", [{}])[0]


# annotation에서 줄글 텍스트만 추출 (없으면 422)
def _full_text_from_annotation(annotation: dict) -> str:
    full_text = annotation.get("fullTextAnnotation", {}).get("text", "")
    if not full_text:
        raise HTTPException(status_code=422, detail="이미지에서 텍스트를 인식할 수 없습니다.")
    return full_text


# Google Vision API로 이미지에서 텍스트 추출 (fullTextAnnotation.text만 반환)
async def _extract_raw_text(image_bytes: bytes) -> str:
    annotation = await _call_vision(image_bytes)
    return _full_text_from_annotation(annotation)


# 실제 공백(SPACE/SURE_SPACE/EOL_SURE_SPACE)일 때만 단어 사이 공백을 넣음
_SPACE_BREAK_TYPES = {"SPACE", "SURE_SPACE", "EOL_SURE_SPACE"}


# 문단(paragraph) 안의 단어(symbols)를 이어붙여 하나의 문자열로 합침.
# Vision은 "관람일시"처럼 공백 없는 한글 단어도 시각적 줄바꿈(LINE_BREAK)이 있으면
# 별도 word로 쪼개서 반환하는데, 이걸 무조건 공백으로 이어붙이면 "관람일 시"처럼
# 라벨 사전과 안 맞는 문자열이 됨 - detectedBreak 타입을 봐서 진짜 공백일 때만 삽입
def _paragraph_text(paragraph: dict) -> str:
    words = paragraph.get("words", [])
    parts = []
    for i, word in enumerate(words):
        symbols = word.get("symbols", [])
        parts.append("".join(s.get("text", "") for s in symbols))
        if i == len(words) - 1:
            continue
        break_type = None
        if symbols:
            break_type = symbols[-1].get("property", {}).get("detectedBreak", {}).get("type")
        if break_type in _SPACE_BREAK_TYPES:
            parts.append(" ")
    return "".join(parts).strip()


# Vision boundingBox(vertices 4점) -> (x0, y0, x1, y1)
def _bounding_box(bbox: dict) -> tuple[float, float, float, float]:
    vertices = bbox.get("vertices") or bbox.get("normalizedVertices") or []
    xs = [v.get("x", 0) for v in vertices]
    ys = [v.get("y", 0) for v in vertices]
    if not xs or not ys:
        return (0.0, 0.0, 0.0, 0.0)
    return (min(xs), min(ys), max(xs), max(ys))


# 문단 하나가 실제로는 여러 줄을 담고 있는지 판단하는 기준 배수 (문단 높이가 평균 단어
# 높이의 이 배수를 넘으면 여러 줄이 뭉친 것으로 판단)
_MULTI_LINE_HEIGHT_RATIO = 1.6


# 문단(paragraph) 하나가 실제로는 세로로 여러 줄(예: 관람일/공연장소/매수처럼 서로 다른
# 값이 각각 다른 줄인데 Vision이 한 덩어리로 묶어버린 경우)을 담고 있으면, 그 문단의
# word bbox들을 Y좌표로 재클러스터링해서 줄 단위로 쪼갠다. 대부분의 문단(한 줄짜리)은
# 평균 단어 높이 대비 문단 높이가 크지 않아 이 함수를 그대로 통과하므로, 정상 케이스엔
# 영향이 없고 실제로 여러 줄이 뭉친 비정상 케이스만 국소적으로 보정된다
def _split_multiline_paragraph(paragraph: dict) -> list[dict]:
    words = paragraph.get("words", [])
    if len(words) < 2:
        return [paragraph]

    word_items = []
    for word in words:
        x0, y0, x1, y1 = _bounding_box(word.get("boundingBox", {}))
        word_items.append({"x0": x0, "y0": y0, "x1": x1, "y1": y1, "word": word})

    heights = [w["y1"] - w["y0"] for w in word_items]
    avg_height = sum(heights) / len(heights) if heights else 0
    _, para_y0, _, para_y1 = _bounding_box(paragraph.get("boundingBox", {}))
    para_height = para_y1 - para_y0

    if avg_height <= 0 or para_height <= avg_height * _MULTI_LINE_HEIGHT_RATIO:
        return [paragraph]

    # word bbox를 Y좌표로 줄 단위 클러스터링 (_group_rows와 동일한 방식)
    ordered = sorted(word_items, key=lambda w: (w["y0"] + w["y1"]) / 2)
    lines: list[list[dict]] = [[ordered[0]]]
    line_center = (ordered[0]["y0"] + ordered[0]["y1"]) / 2
    for w in ordered[1:]:
        height = (w["y1"] - w["y0"]) or 1
        center = (w["y0"] + w["y1"]) / 2
        if abs(center - line_center) <= height * 0.6:
            lines[-1].append(w)
        else:
            lines.append([w])
        line_center = sum((x["y0"] + x["y1"]) / 2 for x in lines[-1]) / len(lines[-1])

    if len(lines) < 2:
        return [paragraph]

    result = []
    for line in lines:
        line.sort(key=lambda w: w["x0"])
        xs0 = [w["x0"] for w in line]
        ys0 = [w["y0"] for w in line]
        xs1 = [w["x1"] for w in line]
        ys1 = [w["y1"] for w in line]
        result.append({
            "words": [w["word"] for w in line],
            "boundingBox": {"vertices": [
                {"x": min(xs0), "y": min(ys0)}, {"x": max(xs1), "y": min(ys0)},
                {"x": max(xs1), "y": max(ys1)}, {"x": min(xs0), "y": max(ys1)},
            ]},
        })
    return result


# annotation의 문단 계층을 (텍스트, bbox) 평면 리스트로 변환
def _flatten_paragraphs(annotation: dict) -> list[dict]:
    blocks = []
    pages = annotation.get("fullTextAnnotation", {}).get("pages", [])
    for page in pages:
        for block in page.get("blocks", []):
            for paragraph in block.get("paragraphs", []):
                for sub_paragraph in _split_multiline_paragraph(paragraph):
                    text = _paragraph_text(sub_paragraph)
                    if not text:
                        continue
                    x0, y0, x1, y1 = _bounding_box(sub_paragraph.get("boundingBox", {}))
                    blocks.append({"text": text, "x0": x0, "y0": y0, "x1": x1, "y1": y1})
    return blocks


# bbox 리스트를 Y좌표로 같은 행끼리 묶고(중심 Y가 블록 높이의 60% 이내면 같은 행),
# 각 행 안에서는 X좌표로 정렬 (라벨이 왼쪽, 값이 오른쪽에 오도록) - 사이트별 좌표를
# 저장하지 않고 이미지마다 새로 계산하므로 화면비율/기기/사이트 리뉴얼에 영향받지 않음
def _group_rows(blocks: list[dict]) -> list[list[dict]]:
    if not blocks:
        return []

    ordered = sorted(blocks, key=lambda b: (b["y0"] + b["y1"]) / 2)
    rows: list[list[dict]] = [[ordered[0]]]
    row_center = (ordered[0]["y0"] + ordered[0]["y1"]) / 2

    for b in ordered[1:]:
        height = (b["y1"] - b["y0"]) or 1
        center = (b["y0"] + b["y1"]) / 2
        if abs(center - row_center) <= height * 0.6:
            rows[-1].append(b)
        else:
            rows.append([b])
        row_center = sum((x["y0"] + x["y1"]) / 2 for x in rows[-1]) / len(rows[-1])

    for row in rows:
        row.sort(key=lambda b: b["x0"])
    return rows


# "좌석(1)"처럼 붙는 개수 표기 제거 후 라벨 텍스트 정규화
def _normalize_row_label(text: str) -> str:
    return _ROW_LABEL_SUFFIX_RE.sub("", text).strip()


# 행 리스트에서 라벨 사전에 매칭되는 행만 골라 {필드: 값} 딕셔너리로 변환. 라벨은
# 행의 첫 블록만 보지 않고 위치 무관하게 찾음 - 포스터 썸네일 텍스트 등 무관한 블록이
# 라벨보다 왼쪽(먼저)에 섞여 들어와도(실사용 캡처로 확인된 케이스) 인식이 깨지지 않게
# 하기 위함. 매칭된 라벨 뒤(오른쪽)의 블록들을 값으로 채택.
# 같은 필드가 여러 행에 매칭되면 문서 순서상 먼저 나온 값을 채택(기존 _extract_price의
# "첫 번째 값 채택" 관례와 동일). 격자가 시작된 첫 행 인덱스도 함께 반환(제목 탐색 범위 한정용)
def _extract_fields_from_rows(rows: list[list[dict]]) -> tuple[dict, int | None]:
    fields: dict = {}
    grid_start_row_index = None
    for i, row in enumerate(rows):
        if len(row) < 2:
            continue
        label_pos, field = None, None
        for j, block in enumerate(row[:-1]):
            candidate = _ROW_LABEL_FIELD.get(_normalize_row_label(block["text"]))
            if candidate:
                label_pos, field = j, candidate
                break
        if field is None:
            continue
        row = row[label_pos:]
        if grid_start_row_index is None:
            grid_start_row_index = i
        if field not in fields:
            fields[field] = " ".join(b["text"] for b in row[1:]).strip()
    return fields, grid_start_row_index


# "관람일시"/"관람일" 행의 값에서 날짜/시간 분리 추출
def _parse_datetime_value(value: str) -> tuple[str | None, str | None]:
    dm = _DATE_RE.search(value)
    date = None
    if dm:
        if dm.group(1):
            date = _parse_date(dm.group(1), dm.group(2), dm.group(3))
        else:
            date = _parse_date(dm.group(4), dm.group(5), dm.group(6))
    return date, _extract_time(value)


# 실제 공연명은 화면 가로폭의 상당 부분을 차지하는 경향이 있는 반면(실사용 4샘플
# 실측 70~96%), 포스터 썸네일/로고 텍스트는 훨씬 좁음(실측 2~35%) - 이미지에서 관측된
# 최대 가로폭(페이지 폭 근사치) 대비 이 비율 미만인 블록은 제목 후보에서 제외
_MIN_TITLE_WIDTH_RATIO = 0.5


# 제목이 화면 폭 제약으로 2줄에 걸쳐 줄바꿈되는 경우, 바로 다음 행이 제목 행과 좌측
# 정렬이 비슷하고 폭도 어느 정도 있으면 줄바꿈 연속으로 보고 이어붙인 후보를 만든다.
# 줄바꿈이 항상 단어 경계에서 일어나는 게 아니라서(실사용 샘플에서 "...HORO" I" +
# "N SEOUL" -> "...HORO" IN SEOUL"처럼 단어 중간에 끊긴 경우가 확인됨) 공백 포함/미포함
# 두 버전 다 만들어서 title_candidates에 넘기고, 어느 쪽이 맞는지는 KOPIS 부분검색+
# 날짜 교차검증(기존 재시도 메커니즘)에 맡긴다 - 원본 title 자체는 바꾸지 않고 보강만 함
_WRAP_X_TOLERANCE = 60
_WRAP_MIN_WIDTH_RATIO = 0.15


def _title_wrap_variants(
    rows: list[list[dict]], title_row_index: int, title_block: dict, page_width: float
) -> list[str]:
    if title_row_index + 1 >= len(rows):
        return []
    next_row = rows[title_row_index + 1]
    if not next_row:
        return []
    next_block = next_row[0]
    text = next_block["text"].strip()
    if not text or not min_len_ok(text):
        return []
    if _LAYOUT_TITLE_SKIP.match(text) or _STATUS_BAR_RE.match(text):
        return []
    if abs(next_block["x0"] - title_block["x0"]) > _WRAP_X_TOLERANCE:
        return []
    if (next_block["x1"] - next_block["x0"]) / page_width < _WRAP_MIN_WIDTH_RATIO:
        return []
    base = title_block["text"].strip()
    return [base + text, f"{base} {text}"]


# 격자 시작 전(헤더 영역) 행에서 라벨-값 매칭이 안 되는 공연명을 별도로 탐색.
# 라벨:값 방식이 아니라 상단 텍스트 블록 중 UI 뱃지/섹션헤더/카테고리 태그/아이콘
# 오인식이 아니고, 화면 폭 대비 충분히 넓은 첫 블록을 채택
# (읽기 순서상 가장 위, 같은 행이면 왼쪽 우선). 줄바꿈 연속 후보도 함께 반환
def _extract_title_from_layout(
    rows: list[list[dict]], grid_start_row_index: int | None
) -> tuple[str | None, list[str]]:
    all_blocks = [b for row in rows for b in row]
    if not all_blocks:
        return None, []
    page_width = max(b["x1"] for b in all_blocks) or 1

    limit = grid_start_row_index if grid_start_row_index is not None else len(rows)
    for i, row in enumerate(rows[:limit]):
        for block in row:
            text = block["text"].strip()
            if not text or not min_len_ok(text):
                continue
            if _LAYOUT_TITLE_SKIP.match(text) or _STATUS_BAR_RE.match(text):
                continue
            if not _HAS_REAL_CONTENT_RE.search(text):
                continue
            if _DATE_RE.match(text) or _PRICE_RE.match(text):
                continue
            if (block["x1"] - block["x0"]) / page_width < _MIN_TITLE_WIDTH_RATIO:
                continue
            return text, _title_wrap_variants(rows, i, block, page_width)
    return None, []


# 예매내역 사이트가 제목이 길면 화면에서 "…"로 줄여 보여주는 경우가 있음 - 잘린 부분
# 자체는 화면에 없으니 복원할 수 없지만, 말줄임표를 검색어에 그대로 남기면 KOPIS
# 검색만 방해되므로 제거. 잘려서 못 찾으면 title_candidates의 다른(더 짧은) 후보로
# 재시도하는 기존 메커니즘에 맡긴다
_TRAILING_ELLIPSIS_RE = re.compile(r"\s*(?:\.{3,}|…)\s*$")


def _strip_trailing_ellipsis(text: str) -> str:
    return _TRAILING_ELLIPSIS_RE.sub("", text).strip()


# 좌표 기반 격자(라벨:값) 레이아웃 파싱 시도. 격자로 판단할 만큼 라벨이 충분히
# 매칭되지 않으면 None을 반환해서 호출부가 기존 regex 파이프라인으로 폴백하게 함
def _parse_ticket_fields_from_layout(annotation: dict, raw_text: str) -> dict | None:
    rows = _group_rows(_flatten_paragraphs(annotation))
    fields, grid_start_row_index = _extract_fields_from_rows(rows)

    if "datetime" not in fields or len(fields) < _MIN_LAYOUT_FIELD_MATCHES:
        return None

    date, time = _parse_datetime_value(fields.get("datetime", ""))
    title, title_wrap_variants = _extract_title_from_layout(rows, grid_start_row_index)
    title = title or _extract_title(raw_text)
    if title:
        title = _strip_trailing_ellipsis(title)
    else:
        title_wrap_variants = []

    platform = _extract_platform(fields.get("platform", "")) if "platform" in fields else None
    if platform is None:
        platform = _extract_platform(raw_text)

    price = None
    if "price" in fields:
        pm = _PRICE_RE.search(fields["price"])
        if pm:
            raw = pm.group(1).replace(",", "")
            if raw.isdigit() and int(raw) >= 1000:
                price = int(raw)
    if price is None:
        price = _extract_price(raw_text)

    title_candidates = ([title] if title else []) + title_wrap_variants + [
        c for c in _extract_title_candidates(raw_text)
        if c != title and c not in title_wrap_variants
    ]

    return {
        "title": title,
        "title_candidates": title_candidates,
        "date": date,
        "time": time,
        "shipping_date": _extract_shipping_date(raw_text),
        "location": fields.get("location"),
        # 예매내역 캡처는 좌석 라벨 자체가 없는 경우가 많아 자연히 None이 되는데, 그건
        # 그대로 둠(자유 텍스트 입력 없이 실제 배송된 티켓 스캔으로 나중에 채우기로 결정).
        # 다만 좌석 라벨이 실제로 인식되면(그리드 구조상 드물게 실물 티켓이 이 경로를 타는
        # 경우 포함) 그 값을 버리지 않고 그대로 사용 - 인식된 정확한 값을 일부러 폐기할
        # 이유가 없다고 확인함(사용자 확인, 2026-08-04)
        "seat": fields.get("seat"),
        "platform": platform,
        "price": price,
        "event_type": _classify_event_type(f"{title or ''}\n{raw_text}"),
    }


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


# 공연명 후보가 될 수 있는 줄 전부 반환 (라벨/날짜/가격/좌석 등 노이즈 줄만 제외, 순서 유지)
def _title_line_candidates(text: str) -> list[str]:
    candidates = []
    for line in text.splitlines():
        line = line.strip()
        if not line or not min_len_ok(line) or len(line) > 80:
            continue
        if _DATE_RE.match(line):
            continue
        if _PRICE_RE.match(line):
            continue
        if _LABEL_SKIP.match(line):
            continue
        # "2024 HA HYUN SANG CONCERT"처럼 연도로 시작하는 제목은 통과시키고,
        # 그 외 숫자로 시작하는 줄(예매번호/좌석코드 등)만 제외
        if re.match(r"^\d", line) and not re.match(r"^(19|20)\d{2}\s", line):
            continue
        # "비지정석"처럼 라벨 없이 좌석 등급만 단독으로 적힌 줄은 공연명이 아니므로 제외
        if _SEAT_RE.fullmatch(line):
            continue
        candidates.append(line)
    return candidates


# 공연명 추출 (레이블 우선 → 첫 번째 유효 줄 폴백)
def _extract_title(text: str) -> str | None:
    m = re.search(r"(?:공연명|행사명|제목)\s*[:：]\s*(.+)", text)
    if m:
        return m.group(1).strip()

    candidates = _title_line_candidates(text)
    return candidates[0] if candidates else None


# 공연명 후보 목록 추출 (첫 줄이 KOPIS 등록명과 표기가 달라 검색이 실패할 때
# "빨래는 오늘을 살아가는" -> "빨래"처럼 뒤쪽 줄로도 KOPIS 검색을 재시도하기 위함)
def _extract_title_candidates(text: str) -> list[str]:
    m = re.search(r"(?:공연명|행사명|제목)\s*[:：]\s*(.+)", text)
    labeled = [m.group(1).strip()] if m else []
    return labeled + _title_line_candidates(text)


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

    # 위 패턴 다 실패하면 세로 나열 폴백 시도 (_STACKED_DATE_RE 주석 참고)
    sm = _STACKED_DATE_RE.search(text)
    if sm:
        return _parse_date(sm.group(3), sm.group(1), sm.group(2))

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

    # "좌석"은 등급명이 아니라 일반 단어("좌석 안내" 등)라서 매칭돼도 건너뛰고 다음 후보를 찾음
    for sm in _SEAT_RE.finditer(text):
        if sm.group(1) == "좌석":
            continue
        return sm.group(0).strip()
    return None


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
        "title":            _extract_title(raw_text),
        # KOPIS 검색이 title로 실패할 때 순서대로 재시도할 대체 후보들 (title 포함, 중복 없이)
        "title_candidates": _extract_title_candidates(raw_text),
        "date":             _extract_concert_date(raw_text),
        "time":             _extract_time(raw_text),
        "shipping_date":    _extract_shipping_date(raw_text),
        "location":         _extract_location(raw_text),
        "seat":             _extract_seat(raw_text),
        "platform":         _extract_platform(raw_text),
        "price":            _extract_price(raw_text),
        "event_type":       _classify_event_type(raw_text),
    }


# 이미지 -> JPEG 변환 -> Vision OCR -> 좌표 기반 격자 파싱 시도 -> 실패 시 로컬 regex 파싱
async def extract_ticket_info(image_bytes: bytes, content_type: str) -> dict:
    loop = asyncio.get_running_loop()
    jpeg_bytes = await loop.run_in_executor(None, _to_jpeg, image_bytes, content_type)
    annotation = await _call_vision(jpeg_bytes)
    raw_text = _full_text_from_annotation(annotation)

    layout_fields = _parse_ticket_fields_from_layout(annotation, raw_text)
    if layout_fields is not None:
        return layout_fields

    return _parse_ticket_fields(raw_text)
