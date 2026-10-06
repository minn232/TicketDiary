import asyncio
import io
import logging
import re

from PIL import Image

from app.services.ocr import _bounding_box, call_vision, to_jpeg

logger = logging.getLogger(__name__)

# 같은 줄로 볼 단어 y중심 허용오차(px)
_LINE_Y_TOLERANCE = 12
# 앞 시간 줄 아래끝~다음 시간 줄 위끝 빈 틈이 이 값 이하면 같은 시간표 구간으로 묶음(px)
_CLUSTER_GAP = 140
# 1~2줄짜리 묶음은 예매일정 안내("9/9 2PM~9/11 11:59AM") 같은 잡음이라 버림
_MIN_LINES_PER_RANGE = 3
# 구간 위아래 여백 = 구간 높이 * 비율 + 고정값. 시간표 헤더(날짜/스테이지명)까지 포함시키려는 것
_PAD_RATIO = 0.15
_PAD_PX = 30

# ocr.py _TIME_RE 기반이지만 콜론 앞뒤 공백을 허용함. Vision이 "13:30"을 "13"/":"/"30"
# 세 단어로 쪼개는 경우가 있어 줄 재조합 결과가 "13 : 30"이 되기 때문
_TIME_RE = re.compile(
    r"오후\s*\d{1,2}시"
    r"|오전\s*\d{1,2}시"
    r"|(?<!\d)\d{1,2}\s{0,2}:\s{0,2}\d{2}(?!\d)"
)

# 같은 줄에 날짜가 붙은 시간 줄은 예매일정/배송/운영시간 안내("2026년 9월 14일(월) 14:00")라 제외.
# 실제 시간표는 날짜가 표 머리에만 있고 시간 줄엔 없음(서버 스크린샷 44건 실측)
_DATE_RE = re.compile(r"\d{4}\s*[년./-]\s*\d{1,2}|\d{1,2}\s*월\s*\d{1,2}\s*일")


# Vision 응답의 단어들을 (y0, y1, text) 줄 단위로 묶음. 문단 경계와 무관하게 y좌표만 봄 -
# 시간표는 시간/아티스트가 서로 다른 문단으로 잡히는 경우가 많기 때문
def _group_words_into_lines(annotation: dict) -> list[tuple[float, float, str]]:
    words = []
    for page in annotation.get("fullTextAnnotation", {}).get("pages", []):
        for block in page.get("blocks", []):
            for paragraph in block.get("paragraphs", []):
                for word in paragraph.get("words", []):
                    text = "".join(s.get("text", "") for s in word.get("symbols", []))
                    x0, y0, x1, y1 = _bounding_box(word.get("boundingBox", {}))
                    if text:
                        words.append((x0, y0, y1, text))

    lines: list[list] = []  # [y중심, y0, y1, [(x0, text), ...]]
    for x0, y0, y1, text in sorted(words, key=lambda w: (w[1] + w[2]) / 2):
        center = (y0 + y1) / 2
        if lines and abs(center - lines[-1][0]) <= _LINE_Y_TOLERANCE:
            line = lines[-1]
            line[1], line[2] = min(line[1], y0), max(line[2], y1)
            line[3].append((x0, text))
        else:
            lines.append([center, y0, y1, [(x0, text)]])

    return [(y0, y1, " ".join(t for _, t in sorted(parts))) for _, y0, y1, parts in lines]


# 시간이 들어간 줄들을 y간격으로 묶어 3줄 이상인 묶음만 시간표 구간으로 보고 (top, bottom) 반환.
# 페스티벌 아티스트 시간표와 단독 공연 당일 일정표(MD/입장/공연 시작) 둘 다 대상
def find_timetable_ranges(annotation: dict, image_height: int) -> list[tuple[int, int]]:
    time_lines = [
        (y0, y1)
        for y0, y1, text in _group_words_into_lines(annotation)
        if _TIME_RE.search(text) and not _DATE_RE.search(text)
    ]

    clusters: list[list[tuple[float, float]]] = []
    for y0, y1 in time_lines:
        if clusters and y0 - clusters[-1][-1][1] <= _CLUSTER_GAP:
            clusters[-1].append((y0, y1))
        else:
            clusters.append([(y0, y1)])

    ranges = []
    for cluster in clusters:
        if len(cluster) < _MIN_LINES_PER_RANGE:
            continue
        top = min(y0 for y0, _ in cluster)
        bottom = max(y1 for _, y1 in cluster)
        pad = (bottom - top) * _PAD_RATIO + _PAD_PX
        ranges.append((max(0, int(top - pad)), min(image_height, int(bottom + pad))))
    return ranges


# 원본 높이 + Vision 전송용 JPEG (동기, run_in_executor 전용 - 세로로 긴 스크린샷 디코딩이 이벤트 루프를 막음)
def _prepare_image(image_bytes: bytes) -> tuple[int, bytes]:
    return Image.open(io.BytesIO(image_bytes)).height, to_jpeg(image_bytes, "image/png")


# 크롤링 스크린샷(PNG)에서 시간표 구간 세로 범위를 계산해 LLM에 넘길 형태([[top, bottom], ...])로 반환.
# Vision 호출 실패 시 None - 스크린샷 저장은 막지 않고 범위만 "미계산"으로 남겨 백필 대상이 되게 함
async def compute_timetable_ranges(image_bytes: bytes) -> list[list[int]] | None:
    try:
        loop = asyncio.get_running_loop()
        image_height, jpeg_bytes = await loop.run_in_executor(None, _prepare_image, image_bytes)
        annotation = await call_vision(jpeg_bytes)
    except Exception as e:
        logger.warning(f"시간표 구간 계산 실패(Vision): {e}")
        return None

    # Vision이 큰 이미지를 줄여서 읽었으면 좌표를 원본 픽셀 기준으로 되돌림(LLM은 원본에서 자름)
    pages = annotation.get("fullTextAnnotation", {}).get("pages", [])
    scale = image_height / pages[0]["height"] if pages and pages[0].get("height") else 1.0
    ranges = find_timetable_ranges(annotation, round(image_height / scale))
    return [[int(top * scale), min(image_height, int(bottom * scale))] for top, bottom in ranges]
