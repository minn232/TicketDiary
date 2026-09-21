"""
타임테이블 영역만 잘라낸 이미지(URL 또는 로컬 파일, 예: ../timetable_image/*.png)를
Qwen2.5-VL-7B-Instruct-AWQ(vLLM 서버)에 전달해 아티스트 목록(lineup)과 타임테이블(timetable)을
JSON으로 추출한다. 모델 출력 스키마는 전용 TIMETABLE_INFO_SCHEMA(timetable_schema.py)이고, 결과 파일은
poster_image/results와 같은 형식으로 바꿔 저장한다(티켓/배송/가격/음식물 필드는 항상 null).

사전 준비:
    vllm serve Qwen/Qwen2.5-VL-7B-Instruct-AWQ \
        --quantization awq \
        --max-model-len 65536 \
        --mm-processor-kwargs '{"max_pixels": 3000000, "min_pixels": 3136}' \
        --limit-mm-per-prompt '{"image": 32}'

사용:
    venv/bin/python server/extract_from_timetable.py timetable_image/*.png --out-dir ./timetable_results

"""

import argparse
import base64
import io
import json
import math
import re
import sys
import time
from pathlib import Path

import numpy as np
import requests
from openai import OpenAI
from PIL import Image

from extract_poster import _looks_like_admission_notice
from timetable_schema import TIMETABLE_INFO_SCHEMA

MODEL_NAME = "Qwen/Qwen2.5-VL-7B-Instruct-AWQ"

# 모델에 보내는 이미지 1장의 최대 픽셀 수. 서버의 --mm-processor-kwargs max_pixels 와 맞춰둔다.
# 넘으면 여기서 직접 비율을 유지한 채 축소한다(서버가 알아서 줄이게 두지 않고 리샘플링 품질을 고정).
MAX_PIXELS = 2_500_000
# 타임테이블 이미지는 한 장으로 보낸다(자르지 않음). 예전의 세로 타일링은 상세페이지용이라
# 격자형 시간표를 가로로 자르면 아래 조각에 무대/날짜 헤더가 빠져 무대 매핑이 불가능했다.
# 대신 좌우/상하의 단색 여백을 먼저 잘라내 픽셀 예산을 실제 내용에 쓴다.
# 한 열(또는 행)의 픽셀 표준편차가 이 값 이하면 "단색 여백"으로 본다(JPEG 노이즈 여유 포함).
MARGIN_STD_THRESHOLD = 6.0
# 여백을 잘라낼 때 내용 가장자리에 남겨두는 여유(px) - 테두리 선/글자 끝이 딱 붙어 잘리지 않게.
MARGIN_PAD_PX = 12
# vLLM 요청 1건당 최대 대기 시간(초). 이 시간을 넘기면 타임아웃 예외를 던지고 다음 이미지로 넘어간다.
REQUEST_TIMEOUT_SEC = 180
# 결과 파일에 "_pipeline_version"으로 같이 남겨서 어떤 코드로 만든 결과인지 구분한다
# (extract_poster.py의 PIPELINE_VERSION과 같은 용도).
PIPELINE_VERSION = "2026-09-21-timetable-5"

SYSTEM_PROMPT = """\
당신은 공연/페스티벌 상세페이지에서 타임테이블(시간표) 부분만 잘라낸 이미지를 보고, 시간표를 정형 데이터로 옮기는 어시스턴트입니다.
이미지에 인쇄된 글자만 근거로 답하세요. 이미지에 없는 정보는 null 또는 빈 배열로 두고, 절대로 추측하거나 지어내지 마세요.

[필드별 답하는 법]
- event_category: 서로 다른 아티스트 둘 이상의 공연 시각이 적힌 시간표면 "festival", 아니면 "other".
- lineup_source: festival이면 "timetable_only", 출연자가 하나도 안 보이면 "none", other면 null.
- lineup_artist_count: 시간표에 적힌 출연자 수. 없으면 null.
- lineup: timetable에 적은 출연자와 날짜를 같은 표기로 옮깁니다.
- timetable_layout: 무대(또는 날짜) 열이 가로로 늘어선 격자형 표면 "grid", 줄마다 시각과 출연자가 붙은 목록이면 "list", 시간표가 없으면 "none".
- timetable_present / timetable: 시간표가 있으면 true와 항목 배열, 없으면 false와 null.

[timetable 항목 규칙]
- 출연자와 시각이 함께 인쇄된 블록마다 항목을 하나 만듭니다. 이미지를 무대 열(또는 날짜 블록)마다 위에서 아래로 끝까지 훑으세요.
- time_text: 블록 안이나 바로 옆에 인쇄된 시각 글자를 보이는 그대로 옮겨 씁니다. 종료 시각이나 소요 시간이 함께 적혀 있으면 그것까지 그대로 씁니다("13:00 - 13:40 (40)"이면 "13:00 - 13:40 (40)"). 24시간제로 바꾸거나 고치지 마세요. 표 옆의 시간축 눈금 숫자는 블록의 시각이 아니므로 옮기지 마세요. 블록에 시각 글자가 없으면 항목을 만들지 마세요.
- artist: 블록에 인쇄된 이름을 그대로 씁니다. 국문과 영문이 함께 적혀 있으면 더 크게 적힌 것 하나만 씁니다.
- stage: 표 맨 위에 무대별 열 제목이 있으면, 그 블록이 속한 열의 제목을 이미지 표기 그대로 씁니다. 그런 열 제목이 없으면 null입니다. 날짜, 배지, 회차 표시는 무대가 아닙니다.
- performance_date: 그 블록이 속한 표나 열의 날짜 헤더에서 월/일을 읽어 YYYY-MM-DD로 씁니다. 날짜가 여러 개면 블록마다 자기 날짜를 씁니다. 연도가 이미지에 없으면 2000으로 씁니다(연도는 나중에 따로 채웁니다). 날짜 헤더가 잘려 월/일이 안 보이면 null이고, 월/일을 지어내지 마세요. 이미지 맨 아래 가장자리에 걸친 다음 표의 날짜는 위쪽 블록의 날짜가 아닙니다.
- 관객 입장 시작 시각(DOOR OPEN, GATE OPEN, 입장 시작 등)은 artist에 그 문구를 그대로 쓴 항목으로 만듭니다.
- 워크숍, 포럼, 팬미팅, 마켓 같은 부대 프로그램과 티켓부스·대기·종료 안내는 항목으로 만들지 마세요.
- 시간표가 아닌 이미지(페이지 머리글, 가격표, 공연 정보 표 등)면 lineup=[], timetable=null입니다.

반드시 주어진 JSON 스키마 형식으로만 답하세요.
"""

USER_PROMPT = "이 타임테이블 이미지에서 위 규칙에 따라 아티스트 목록과 타임테이블을 추출해줘."


def load_image(image: str) -> Image.Image:
    if image.startswith("http://") or image.startswith("https://"):
        resp = requests.get(image, timeout=30)
        resp.raise_for_status()
        return Image.open(io.BytesIO(resp.content)).convert("RGB")
    return Image.open(image).convert("RGB")


def _content_span(activity: np.ndarray) -> tuple[int, int]:
    """열(또는 행)별 활동도 배열에서, 양 끝의 단색 여백을 뺀 내용 구간 [lo, hi)를 찾는다.
    전부 단색이면 원래 범위를 그대로 돌려준다."""
    busy = np.flatnonzero(activity > MARGIN_STD_THRESHOLD)
    if busy.size == 0:
        return 0, activity.size
    lo = max(0, int(busy[0]) - MARGIN_PAD_PX)
    hi = min(activity.size, int(busy[-1]) + 1 + MARGIN_PAD_PX)
    return lo, hi


def trim_margins(im: Image.Image) -> Image.Image:
    """상하좌우 가장자리의 단색 여백(흰 배경, 페이지 좌우 배경색 등)을 잘라낸다. 각 열/행 안의
    픽셀 표준편차가 MARGIN_STD_THRESHOLD 이하면 단색으로 본다 - 배경색을 하나로 가정하지 않고
    열/행마다 따로 보므로 왼쪽은 초록, 오른쪽은 흰색처럼 양쪽 여백 색이 달라도 된다.
    크롭 이미지 중 오른쪽 1/3이 통째로 흰 여백인 경우 등이 있어 픽셀 예산 낭비가 컸다."""
    gray = np.asarray(im.convert("L"), dtype=np.float32)
    left, right = _content_span(gray.std(axis=0))
    top, bottom = _content_span(gray.std(axis=1))
    if (left, top, right, bottom) == (0, 0, im.width, im.height):
        return im
    return im.crop((left, top, right, bottom))


def fit_to_pixel_budget(im: Image.Image, max_pixels: int = MAX_PIXELS) -> Image.Image:
    """픽셀 수가 max_pixels를 넘으면 가로세로 비율을 유지한 채 축소한다. 작은 이미지는 키우지 않는다."""
    w, h = im.size
    if w * h <= max_pixels:
        return im
    scale = math.sqrt(max_pixels / (w * h))
    new_size = (max(1, int(w * scale)), max(1, int(h * scale)))
    return im.resize(new_size, Image.Resampling.LANCZOS)


def prepare_image(im: Image.Image) -> Image.Image:
    """모델에 보낼 한 장짜리 이미지를 만든다: 여백 제거 -> 픽셀 예산에 맞게 축소."""
    return fit_to_pixel_budget(trim_margins(im))


def image_to_data_uri(im: Image.Image) -> str:
    buf = io.BytesIO()
    im.save(buf, format="PNG")
    data = base64.b64encode(buf.getvalue()).decode("utf-8")
    return f"data:image/png;base64,{data}"


def extract_timetable_info(
    image: str,
    base_url: str,
    api_key: str = "EMPTY",
    timeout: float = REQUEST_TIMEOUT_SEC,
) -> dict:
    client = OpenAI(base_url=base_url, api_key=api_key, timeout=timeout)

    im = prepare_image(load_image(image))
    content = [
        {"type": "text", "text": USER_PROMPT},
        {"type": "image_url", "image_url": {"url": image_to_data_uri(im)}},
    ]

    response = client.chat.completions.create(
        model=MODEL_NAME,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": content},
        ],
        temperature=0,
        max_tokens=32768,
        response_format={
            "type": "json_schema",
            "json_schema": {
                "name": "timetable_info",
                "schema": TIMETABLE_INFO_SCHEMA,
                "strict": True,
            },
        },
    )

    choice = response.choices[0]
    if choice.finish_reason == "length":
        raise RuntimeError(
            "응답이 max_tokens 한도에 걸려 중간에 잘렸습니다(라인업/타임테이블 항목이 너무 많은 "
            "이미지일 수 있음) - max_tokens를 늘려보세요."
        )

    raw = choice.message.content
    return to_result_format(json.loads(raw))


# 무대 이름이 아닌 stage 값. null로 바꾼다.
#   - 모델이 지어내는 자리표시자("무대1", "Stage 1", 꺾쇠 표기)
#   - 한 글자("A", "B" - allfamily 실측)
#   - 날짜 헤더를 무대로 옮긴 값("10.31토" - sbmf 실측)
_PLACEHOLDER_STAGE_RE = re.compile(
    r"^\s*(무대|스테이지|stage)\s*\d*\s*$|[〈〉<>]|^\s*\S\s*$|\d{1,2}\s*[./]\s*\d{1,2}",
    re.IGNORECASE,
)


# time_text에서 시작 시각을 찾는 패턴. 인쇄된 표기 중 가장 앞에 나오는 것을 시작 시각으로 본다.
#   "12:50 - 13:30 (40')", "20:20 -", "18.30"  -> 시:분
#   "오후 6시", "6시 30분", "6시 반"           -> 한국어 표기
#   "5PM", "5 p.m."                           -> 분 없는 오전/오후 표기
# 숫자만 있는 "13"은 시간축 눈금일 가능성이 커서 일부러 받지 않는다(항목이 버려짐).
_CLOCK_RE = re.compile(r"(\d{1,2})\s*[:：.]\s*(\d{2})")
_KOREAN_HOUR_RE = re.compile(r"(\d{1,2})\s*시(?:\s*(\d{1,2})\s*분|\s*(반))?")
_HOUR_MERIDIEM_RE = re.compile(r"(\d{1,2})\s*(am|pm|a\.m\.|p\.m\.)", re.IGNORECASE)
_PM_RE = re.compile(r"오후|pm|p\.m\.", re.IGNORECASE)
_AM_RE = re.compile(r"오전|am|a\.m\.", re.IGNORECASE)


def parse_start_time(time_text: str | None) -> str | None:
    """블록에 인쇄된 시각 글자에서 시작 시각을 24시간제 "HH:MM"으로 뽑는다. 못 찾으면 None."""
    if not time_text:
        return None
    candidates = []
    if m := _CLOCK_RE.search(time_text):
        candidates.append((m.start(), m.end(), int(m.group(1)), int(m.group(2))))
    if m := _KOREAN_HOUR_RE.search(time_text):
        minute = 30 if m.group(3) else int(m.group(2) or 0)
        candidates.append((m.start(), m.end(), int(m.group(1)), minute))
    if m := _HOUR_MERIDIEM_RE.search(time_text):
        candidates.append((m.start(), m.end(), int(m.group(1)), 0))
    if not candidates:
        return None
    start, end, hour, minute = min(candidates)

    # 오전/오후 표시는 시각 바로 앞(“오후 6시”, “PM 4:30”)이나 바로 뒤(“5PM”)에 붙어 있다.
    around = time_text[max(0, start - 4):end + 5]
    if _PM_RE.search(around) and hour < 12:
        hour += 12
    elif _AM_RE.search(around) and hour == 12:
        hour = 0
    # 자정을 넘긴 "24:30", "25:10" 표기는 다음 날 새벽 시각으로 바꾼다(날짜는 표 제목 날짜 그대로).
    if 24 <= hour < 30:
        hour -= 24
    if not (0 <= hour < 24 and 0 <= minute < 60):
        return None
    return f"{hour:02d}:{minute:02d}"


def _clean_timetable(entries: list[dict]) -> list[dict]:
    """모델 항목을 결과 형식으로 바꾼다: time_text에서 시작 시각(time)을 뽑고, 자리표시자 무대 이름을
    null로 바꾸고, 이름이나 시각이 없는 항목은 버리고, (날짜, 시각, 이름)이 같은 항목은 첫 번째만 남긴다 -
    모델이 같은 이름을 무대만 바꿔가며 반복 생성하는 루프(gmf2025 실측: "Dragon Pony" 60회)를 걷어내기 위함."""
    seen = set()
    cleaned = []
    for e in entries:
        # 모델이 null 대신 문자열 "null"을 쓰는 경우가 있다(akmu_daejeon 실측).
        e = {k: (None if isinstance(v, str) and v.strip().lower() in ("null", "none") else v) for k, v in e.items()}
        stage = e.get("stage")
        if stage and _PLACEHOLDER_STAGE_RE.search(stage):
            stage = None
        # 이름 없는 항목은 쓸모가 없다(akmu_daejeon 실측: 시간축 눈금마다 artist=null 항목 13개).
        artist = (e.get("artist") or "").strip()
        start_time = parse_start_time(e.get("time_text"))
        if not artist or start_time is None:
            continue
        key = (e.get("performance_date"), start_time, artist.casefold())
        if key in seen:
            continue
        seen.add(key)
        cleaned.append({
            "performance_date": e.get("performance_date"),
            "time": start_time,
            "artist": e["artist"],
            "stage": stage,
        })
    return cleaned


def _lineup_from_timetable(timetable: list[dict]) -> list[dict]:
    """lineup은 모델이 따로 답한 목록 대신 timetable 항목에서 만든다(모델 lineup은 timetable보다 누락이
    많았음 - pentaport2026_3 실측 22팀 중 10팀). 같은 아티스트가 여러 번 나와도 항목마다 그대로 둔다.
    이름이 없는 항목과 입장 안내 문구(DOOR OPEN 등)는 아티스트가 아니므로 뺀다."""
    return [
        {"artist": e["artist"], "performance_date": e.get("performance_date")}
        for e in timetable
        if e.get("artist") and not _looks_like_admission_notice(e["artist"])
    ]


def to_result_format(raw: dict) -> dict:
    """모델 응답(TIMETABLE_INFO_SCHEMA)을 poster_image/results와 같은 형식으로 바꾼다(extract_poster.py
    _merge_results의 반환 형식). event_category/lineup_source/lineup_artist_count/timetable_layout/
    timetable_present는 추출 순서를 유도하는 스캐폴딩 필드라 결과에서 뺀다. 타임테이블 이미지에는 티켓/배송/
    가격/음식물 정보가 없으므로 그 필드는 항상 null이다. 빈 timetable은 null로 통일한다."""
    timetable = _clean_timetable(raw.get("timetable") or [])
    return {
        "timetable": timetable or None,
        "lineup": _lineup_from_timetable(timetable),
        "ticketing_date": None,
        "ticket_delivery_date": None,
        "ticket_prices": None,
        "other_info": {"food_allowed": None},
    }


def main():
    parser = argparse.ArgumentParser(description="타임테이블 이미지에서 아티스트 목록과 타임테이블 추출")
    parser.add_argument("images", nargs="+", help="타임테이블 이미지 URL 또는 로컬 파일 경로 (여러 개 가능)")
    parser.add_argument(
        "--base-url",
        default="http://localhost:8000/v1",
        help="vLLM OpenAI 호환 서버 주소 (기본값: http://localhost:8000/v1)",
    )
    parser.add_argument("--api-key", default="EMPTY", help="vLLM은 보통 임의 문자열이면 충분")
    parser.add_argument("--out-dir", default=None, help="지정하면 이미지별 결과를 <파일명>.json으로 저장")
    parser.add_argument(
        "--timeout",
        type=float,
        default=REQUEST_TIMEOUT_SEC,
        help=f"이미지 1장당 요청 최대 대기 시간(초) (기본값: {REQUEST_TIMEOUT_SEC})",
    )
    args = parser.parse_args()

    out_dir = Path(args.out_dir) if args.out_dir else None
    if out_dir:
        out_dir.mkdir(parents=True, exist_ok=True)

    exit_code = 0
    for image in args.images:
        label = Path(image).name if not image.startswith("http") else image
        start = time.monotonic()
        try:
            result = extract_timetable_info(image, args.base_url, args.api_key, timeout=args.timeout)
        except Exception as exc:  # noqa: BLE001
            elapsed = time.monotonic() - start
            print(f"[{label}] 추출 실패 ({elapsed:.1f}초): {exc}", file=sys.stderr)
            exit_code = 1
            continue
        elapsed = time.monotonic() - start

        payload = dict(result)
        payload["_pipeline_version"] = PIPELINE_VERSION
        text = json.dumps(payload, ensure_ascii=False, indent=2)
        if len(args.images) > 1:
            print(f"=== {label} ({elapsed:.1f}초) ===")
        else:
            print(f"({elapsed:.1f}초 소요)")
        print(text)

        if out_dir:
            out_path = out_dir / f"{Path(image).stem}.json"
            out_path.write_text(text, encoding="utf-8")

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
