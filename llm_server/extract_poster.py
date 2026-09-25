"""
공연 소개 이미지(URL 또는 로컬 파일)를 Qwen2.5-VL-7B-Instruct-AWQ(vLLM 서버)에 전달해
타임테이블 / 라인업 / 티켓팅 오픈일 / 티켓 배송일 / 가격 / 음식물 반입 여부를 JSON으로 추출한다.

티켓 상세페이지 캡처 이미지는 세로로 매우 길다(예: 1920x16238). 통째로 모델에 넣으면
비전 인코더가 거대한 단일 이미지를 처리하며 GPU 메모리가 터지거나(OOM), 강제로
축소되면서 하단부 글자가 뭉개진다. 이를 막기 위해 세로로 김/큰 이미지는 겹치는
구간을 두고 여러 조각(타일)으로 자른다.

2026-08-27 변경: 예전에는 자른 타일을 전부 한 요청에 몰아넣었는데, 이미지가 아주 길면
(예: 1300x39632) 타일 수가 상한(18)에 가까워지는 순간 이미지 토큰만으로 서버 컨텍스트
한도(--max-model-len 65536)를 넘어 "Input length exceeds model's maximum context length"
에러가 났다. 또 한 요청 안에서 라인업+타임테이블 전체를 한 번에 나열시키니 응답이 길어져
max_tokens에 걸려 잘리는 경우도 있었다. 지금은 타일을 더 작게+겹침을 더 크게 잘라 경계에
걸친 이름/시간이 최소 한 타일엔 온전히 담기게 하고, 그 타일들을 이미지 토큰 예산 안에서
여러 개의 작은 배치(batch)로 묶어 배치마다 별도 요청을 순서대로 보낸다. 각 배치는 "전체
페이지의 일부 구간"이라는 것과, 그 구간에 날짜 헤더가 안 보이면 performance_date를 null로
두라는 안내를 프롬프트에 추가로 받는다 - 날짜는 나중에 라인업 결과와 아티스트 이름으로
매칭해서 채운다(_merge_results). 배치 경계에도 타일 1장을 겹쳐 보내 배치 사이에서 항목이
잘리는 것도 추가로 막는다. 마지막으로 모든 배치 결과를 합치면서 라인업/타임테이블 중복을
제거한다 - 타일 하나뿐인(안 잘리는) 일반 포스터도 같은 병합 경로를 거쳐, 모델이 한 응답
안에서 같은 항목을 중복 생성하는 경우까지 걸러낸다.

2026-09-07 변경: 아티스트 누락 대응으로 추출 "순서"를 바꿨다. 예전에는 lineup 배열을 곧바로
나열시켰는데, 이미지가 크면 모델이 중간에 훑기를 멈춰 뒷부분 아티스트를 통째로 빠뜨리는 일이
있었다. 지금은 (1) 라인업을 어디서 읽을지(lineup_source) (2) 몇 명인지(lineup_artist_count)를 이름
한 글자 쓰기 전에 먼저 답하게 하고, (3) 그 개수를 목표치로 두고 lineup을 채운 뒤, (4) 시간표가
있으면 timetable을 채우게 한다(2026-09-14: "lineup 목록을 순서대로 짚어가며 시각을 찾으라"던 지시는
뺐다 - 시간표가 안 보이는 구간에서도 이름마다 시각을 지어내, 사운드플래닛 실측에서 라인업 구역
배치가 낸 시각 94개 중 3개만 맞았다. 지금은 시간표 블록 안에 이름과 "HH:MM - HH:MM"이 함께 인쇄된
것만 항목으로 만들게 한다). 순서 강제는 프롬프트만이
아니라 schema.py의 property 선언 순서로 한다 - vLLM의 json_schema strict 디코딩이 선언 순서대로
생성하므로, 앞 단계 답이 뒤 단계 생성 시점의 문맥에 반드시 남는다. 개수를 채우려고 없는 이름을
지어내는 반작용은 프롬프트 금지 + _filter_lineup_noise의 자리표시자 필터로 막고, 그래도 센
개수보다 적게 나열한 배치는 _warn_if_undercounted가 stderr로 알린다. 이 세 스캐폴딩 필드는
_merge_results 반환값에는 넣지 않는다(백엔드 계약 6개 키 유지).

2026-09-13 변경: 추출 절차 맨 앞에 페스티벌/그 외 공연 구분(event_category)을 넣었다. 라인업
구역(또는 여러 아티스트의 시간표)이 보이거나, 라인업이 없어도 "블라인드 티켓"/"얼리버드 티켓"
단어가 있으면 페스티벌이고 기존 절차를 그대로 따른다. 그 외 공연은 lineup_source를 쓰지 않고
(null) 공연명/페이지 상단에서 아티스트를 읽으며, 공연 시작 시각을 아티스트
이름과 함께 timetable에 넣는다. 페스티벌은 아티스트별 공연 시각에 게이트 오픈 시각을 더하며, 입장
항목은 artist에 인쇄된 입장 문구("GATE OPEN" 등)를 그대로 쓴다(timetable에 항목 종류 필드는 두지
않는다 - 코드는 _looks_like_admission_notice로 입장 항목을 알아본다).
배치 병합은 한 배치라도 페스티벌이면 페이지 전체를 페스티벌로 본다(_merge_results). event_category도
스캐폴딩이라 반환값에는 넣지 않는다. 같은 날 타일 1장짜리 일반 포스터 경로를 없애, 모든 이미지를
타일 분할 경로(FRAGMENT_NOTE 포함)로 보낸다.

2026-09-14 변경: few-shot 예시를 추가했다. few_shot_examples/ 폴더의 상세페이지 이미지에서 패턴이
드러나는 조각(타일) 5장과 그 정답(블라인드 티켓, 날짜별 라인업 구역, 리스트형 시간표, 입장 일정표,
날짜 없는 배송 안내)을 매 요청의 system 뒤에 user/assistant 턴으로 붙인다(_FEW_SHOT_EXAMPLES).
POSTER_FEW_SHOT=0으로 끌 수 있다. 같은 날 병합 보정 3가지를 추가했다 - 지어낸 연도를 페이지 연도로
바로잡기(_normalize_years), 예시 정답이 복사된 값 버리기(_drop_few_shot_leaks), 페스티벌 아티스트는
하루 한 슬롯만 남기기(_one_slot_per_artist_day). 또 배치 응답에 시간표 형태(timetable_layout)를 추가해,
"grid"로 답한 배치 구간은 좌우로 자르지 않고 전체 폭 그대로 400px 높이·200px 겹침으로 다시 잘라 2차
추출하고, 그 배치들의 1차 timetable은 버린다(extract_poster_info, split_grid_region).

2026-09-25 변경: extract_from_timetable.py를 이 파일로 합쳤다(프롬프트 텍스트는 prompts.py). 격자형 시간표를
자동으로 찾아 다시 자르던 2차 추출(split_grid_region)을 없애고, 시간표 구간을 호출하는 쪽에서 세로 범위
(timetable_ranges=[(top, bottom), ...])로 받는다. 구간은 extract_from_timetable.py 방식으로 읽는다 - 전체 폭으로
잘라 단색 여백을 떼고(trim_margins) 조각 1장씩 보낸다. 픽셀 예산(TIMETABLE_MAX_PIXELS)을 넘으면 축소하지 않고
세로로 나눈다(split_timetable_region). 출력 스키마는 전용 스키마(time_text) 대신 POSTER_INFO_SCHEMA를 쓴다.
구간이 주어지면 타일에서 읽은 아티스트 시간표는 구간 결과로 대체한다. 구간이 없으면 페스티벌의 아티스트 시간표는
비우고(입장 안내만 남김), 그 외 공연의 공연 시작 시각은 예전처럼 타일 결과를 쓴다(_merge_results).
손으로 자른 시간표 이미지는 --timetable-crop으로 돌린다(이미지 전체를 구간 하나로 본다).
같은 날 few-shot 예시를 뺐다(_FEW_SHOT_EXAMPLES, POSTER_FEW_SHOT, _drop_few_shot_leaks 삭제) - 배치 요청은
system 프롬프트와 조각 이미지만 보낸다. 예시 이미지(few_shot_examples/interpark_*.png)도 폴더에서 지워졌다.

사전 준비:
    vllm serve Qwen/Qwen2.5-VL-7B-Instruct-AWQ \
        --quantization awq \
        --max-model-len 65536 \
        --mm-processor-kwargs '{"max_pixels": 3000000, "min_pixels": 3136}' \
        --limit-mm-per-prompt '{"image": 32}'

사용:
    # URL
    python extract_poster.py "https://example.com/poster.jpg"

    # 로컬 파일 (여러 장 가능, glob도 지원)
    /workspace/venv/bin/python server/extract_poster.py /workspace/poster_image/*.png --out-dir /workspace/poster_image/results
    /workspace/venv/bin/python server/extract_poster.py poster_image/20260815_203732_사운드플래닛페스티벌2026_melon.png
    /workspace/venv/bin/python server/extract_poster.py poster_image/20260815_203816_펜타포트2026_nol.png
    /workspace/venv/bin/python server/extract_poster.py poster_image/20260823_031936_812295_ticket_yes24_com_Perf_54227.png --out-dir /workspace/poster_image/results

    # 시간표 구간(원본 이미지의 세로 픽셀 범위)을 함께 줄 때 - 여러 개면 옵션을 반복
    /workspace/venv/bin/python server/extract_poster.py poster.png --timetable-range 1200:3400 --timetable-range 3600:5200

    # 손으로 자른 시간표 이미지(예전 extract_from_timetable.py)
    /workspace/venv/bin/python server/extract_poster.py --timetable-crop timetable_image/*.png --out-dir /workspace/timetable_results

"""

import argparse
import base64
import io
import json
import math
import re
import sys
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from fractions import Fraction
from functools import partial
from pathlib import Path

import numpy as np
import openai
import requests
from openai import OpenAI
from PIL import Image

from prompts import (
    FRAGMENT_LAYOUT_MANY_COLUMNS,
    FRAGMENT_LAYOUT_NO_COLUMNS,
    FRAGMENT_LAYOUT_TWO_COLUMNS,
    FRAGMENT_NOTE,
    POSTER_SYSTEM_PROMPT,
    POSTER_USER_PROMPT,
    TILE_GROUP_NOTE,
    TIMETABLE_SYSTEM_PROMPT,
    TIMETABLE_USER_PROMPT,
)
from schema import POSTER_INFO_SCHEMA

MODEL_NAME = "Qwen/Qwen2.5-VL-7B-Instruct-AWQ"

# extract.poster.py(모델 호출/후처리 로직)가ㅏ 바뀔 때마다 사람이 올리는 버전 문자열.
# --out-dir로 저장하는 결과 파일에 "_pipeline_version"으로 같이 남김
# grep으로 구버전 결과만 골라내기
# --skip-up-to-date로 최신 버전의 파일 건너뛰기.
PIPELINE_VERSION = "2026-09-25-2"

# ── 업스케일 ────────────────────────────────────────────────────────
# 자른 타일(조각)을 이 수치를 목표로 업스케일링
RENDER_TARGET_PIXELS = 2_000_000
# 타일을 억지로 키워 흐려지는 일이 없도록 상한을 둠
MAX_UPSCALE_FACTOR = 3.0

# ── 타일링 ──────────────────────────────────────────────────────────
# 타일 하나에 담는 "원본" 픽셀 수 상한(모델에 보낼 때의 크기가 아니라, 잘라내는 양의 기준).
MAX_PIXELS_PER_TILE = 600_000
# 타일 간 세로 겹침 픽셀.
TILE_OVERLAP_PX = 200
# 목표 절단 지점(고정 간격) 위아래로 이 범위 안에서 배경색이 가장 뚜렷하게 바뀌는 행을 찾아 자름
# 텍스트나 타임테이블 막대 중간이 그대로 잘리는 것을 피하기 위함.
CUT_SEARCH_RADIUS_PX = 150
# 가로 띠 하나를 세로로 몇 조각으로 나눌지. 1이면 나누지 않는다. 바꾸면 PIPELINE_VERSION도 올릴 것
# (FRAGMENT_NOTE의 조각 설명은 이 값에 맞춰 자동으로 바뀐다).
COLUMN_SPLIT_COUNT = 2
# 한 조각의 폭을 원본의 몇 배로 할지. 조각들은 왼쪽 끝부터 오른쪽 끝까지 같은 간격으로 놓여 이웃끼리 겹친다.
# 조각 수가 2 이상이면 1/COLUMN_SPLIT_COUNT보다 크고 1보다 작아야 한다(아니면 틈이 생기거나 겹침이 없다).
COLUMN_SPLIT_WIDTH_RATIO = 2 / 3
# 이보다 좁은 이미지는 나눠도 조각이 지나치게 좁아져 오히려 읽기 어려워지므로 나누지 않는다.
MIN_WIDTH_FOR_COLUMN_SPLIT = 700
if COLUMN_SPLIT_COUNT < 1 or (
    COLUMN_SPLIT_COUNT > 1 and not 1 / COLUMN_SPLIT_COUNT < COLUMN_SPLIT_WIDTH_RATIO < 1
):
    raise ValueError(
        f"COLUMN_SPLIT_COUNT={COLUMN_SPLIT_COUNT}이면 COLUMN_SPLIT_WIDTH_RATIO는 "
        f"1/{COLUMN_SPLIT_COUNT}보다 크고 1보다 작아야 합니다(지금 {COLUMN_SPLIT_WIDTH_RATIO})."
    )


# 요청 1건에 담을 이미지(타일) 토큰 총량 상한
IMAGE_TOKEN_BUDGET_PER_REQUEST = 40_000
# Qwen2.5-VL은 14x14 픽셀 패치를 2x2로 병합(28x28px)해 1개의 비전 토큰을 만든다 - 근사치.
TOKENS_PER_PIXEL = 1 / (28 * 28)
# 한 요청(배치)에 들어가는 타일 개수 상한.
MAX_TILES_PER_BATCH = 4
# 배치 경계에도 타일을 겹쳐 보낸다
# 배치 N의 마지막 타일을 배치 N+1의 첫 타일로 다시 넣어, 요청이 나뉘는 지점에서 항목이 잘려 유실되는 것을 막는다.
BATCH_OVERLAP_TILES = 1

# 배치(조각 일부)당 응답 토큰 상한. 2026-09-02: MAX_TILES_PER_BATCH를 10->6으로 줄인 것과
# 별개로, 그래도 잘리는 극단적으로 촘촘한 배치를 위해 16,000 -> 20,000으로 올렸다(아래
# _call_batch_with_split_retry가 그래도 잘리면 배치를 절반씩 나눠 재귀적으로 재시도하므로,
# 이 값은 "왠만하면 한 번에 끝나는" 여유 있는 상한 정도의 의미로 조금 더 낮춰도 된다).
BATCH_MAX_TOKENS = 20_000

# vLLM 요청 1건당 최대 대기 시간(초).
# "BATCH_MAX_TOKENS를 실제로 채우는 데 걸리는 시간"에서 역산해 최소 타임아웃을 계산하고, 하한(MIN_REQUEST_TIMEOUT_SEC)과 비교해 더 큰 값을 쓴다
# 두 상수가 앞으로 각자 바뀌어도(예: BATCH_MAX_TOKENS를 더 올림) 다시 어긋나지 않게 자동으로 따라간다.
MIN_OBSERVED_TOKENS_PER_SEC = 35  # vllm.log 관측치(~40-44 tok/s)보다 보수적으로 낮게 잡은 하한
TIMEOUT_MARGIN_MULTIPLIER = 1.3  # 프리필/네트워크 여유분
MIN_REQUEST_TIMEOUT_SEC = 600
REQUEST_TIMEOUT_SEC = max(
    MIN_REQUEST_TIMEOUT_SEC,
    int(BATCH_MAX_TOKENS / MIN_OBSERVED_TOKENS_PER_SEC * TIMEOUT_MARGIN_MULTIPLIER),
)

# 배치 병렬화(2026-09-02 추가): 더 올리려면 vllm.log의 KV cache usage를 다시 보고 판단할 것.
BATCH_CONCURRENCY = 16


# 프롬프트 텍스트(POSTER_SYSTEM_PROMPT, FRAGMENT_NOTE, POSTER_USER_PROMPT, TILE_GROUP_NOTE)는 prompts.py에 있다.


def _batch_user_content(tile_group: list[Image.Image]) -> list[dict]:
    """배치 요청의 user 턴 content."""
    content = [
        {"type": "text", "text": POSTER_USER_PROMPT},
        {"type": "text", "text": TILE_GROUP_NOTE.format(count=len(tile_group))},
    ]
    for tile in tile_group:
        content.append({"type": "image_url", "image_url": {"url": image_to_data_uri(tile)}})
    return content


def load_image(image: str) -> Image.Image:
    if image.startswith("http://") or image.startswith("https://"):
        resp = requests.get(image, timeout=30)
        resp.raise_for_status()
        return Image.open(io.BytesIO(resp.content)).convert("RGB")
    return Image.open(image).convert("RGB")


def _row_activity(im: Image.Image) -> np.ndarray:
    """각 행(가로 한 줄) 안에서 픽셀 값이 얼마나 들쭉날쭉한지를 표준편차로 나타낸다. shape (h,).
    값이 0에 가까우면 그 행은 배경색뿐인 빈 줄(여백)이라는 뜻이고, 값이 크면 글자/그래프/표
    선 등이 지나간다는 뜻이다. 절단선을 고를 때 이 값이 가장 작은(가장 비어 있는) 행을 고르면
    텍스트나 타임테이블 막대 한가운데를 피할 수 있다.

    (예전에는 '바로 위 행과 색이 가장 크게 차이 나는 행'을 절단선으로 썼는데, 타임테이블처럼
    표 전체가 촘촘한 색 블록으로 채워진 구간은 어느 행이든 위 행과 색이 다르므로 결국 표
    한가운데(칸과 칸 사이 경계선)에서 잘리는 문제가 있었다. 행 자체의 활동도가 낮은 지점을
    찾는 방식은 실제 여백(빈 줄)을 우선하므로 이런 문제를 피한다.)"""
    arr = np.asarray(im, dtype=np.float32)
    return arr.std(axis=(1, 2))


def _find_cut_row(row_activity: np.ndarray, target: int, top: int, h: int) -> int:
    """target 이전 구간(target - CUT_SEARCH_RADIUS_PX ~ target, top<row<=target 범위 내)에서
    가장 활동도가 낮은(가장 비어 있는) 행을 찾는다 - 텍스트나 타임테이블 막대, 표 선 등이
    지나가지 않는 여백 줄을 절단선으로 쓰기 위함. target보다 뒤쪽은 보지 않는다 - 타일이
    MAX_PIXELS_PER_TILE 예산을 넘어가면 vLLM이 강제로 축소해서 작은 글자가 더 뭉개지기 때문."""
    search_lo = max(top + 1, target - CUT_SEARCH_RADIUS_PX)
    search_hi = min(h, target)
    if search_lo >= search_hi:
        return target
    window = row_activity[search_lo:search_hi]
    return search_lo + int(np.argmin(window))


def _band_coords(row_activity: np.ndarray, start: int, end: int, tile_h: int, overlap: int) -> list[tuple[int, int]]:
    """[start, end) 세로 구간을 tile_h 높이, overlap만큼 겹치는 띠들의 (top, bottom) 좌표로 나눈다.
    절단선은 _find_cut_row로 여백 줄을 고른다."""
    bands = []
    top = start
    while top < end:
        target_bottom = min(end, top + tile_h)
        bottom = target_bottom if target_bottom >= end else _find_cut_row(row_activity, target_bottom, top, end)
        bands.append((top, bottom))
        if bottom >= end:
            break
        top = max(top + 1, bottom - overlap)
    return bands


def _tile_at_height(im: Image.Image, row_activity: np.ndarray, tile_h: int) -> list[Image.Image]:
    w, h = im.size
    return [im.crop((0, top, w, bottom)) for top, bottom in _band_coords(row_activity, 0, h, tile_h, TILE_OVERLAP_PX)]


def _split_columns(im: Image.Image) -> list[Image.Image]:
    """가로 띠 하나를 세로로 COLUMN_SPLIT_COUNT개 조각으로 나눠 왼쪽부터 돌려준다. 각 조각의 폭은 원본의
    COLUMN_SPLIT_WIDTH_RATIO배이고, 조각들을 왼쪽 끝부터 오른쪽 끝까지 같은 간격으로 놓아 이웃끼리 겹치게
    한다(기본값 2개·2/3이면 왼쪽 0~2w/3, 오른쪽 w/3~w로 가운데 1/3이 양쪽에 들어간다) - 경계선에 걸친
    아티스트 이름/타임테이블 칸이 최소 한쪽에는 온전히 담기게 하기 위함. 너무 좁은 이미지는
    나누지 않고 그대로 돌려준다."""
    w, h = im.size
    col_w = _column_tile_width(w)
    if col_w == w:
        return [im]
    step = (w - col_w) / (COLUMN_SPLIT_COUNT - 1)
    return [im.crop((x, 0, x + col_w, h)) for x in (int(round(i * step)) for i in range(COLUMN_SPLIT_COUNT))]


def _upscale_to_budget(im: Image.Image) -> Image.Image:
    """최종 타일을 RENDER_TARGET_PIXELS까지 확대한다(축소는 하지 않음). 이미 예산 이상이면
    그대로 두고, 확대 배율은 MAX_UPSCALE_FACTOR로 제한한다."""
    w, h = im.size
    pixels = w * h
    if pixels >= RENDER_TARGET_PIXELS:
        return im
    scale = min((RENDER_TARGET_PIXELS / pixels) ** 0.5, MAX_UPSCALE_FACTOR)
    if scale <= 1.0:
        return im
    return im.resize((max(1, int(w * scale)), max(1, int(h * scale))), Image.LANCZOS)


def _column_tile_width(w: int) -> int:
    """_split_columns로 나눈 조각 하나의 폭. 타일 높이를 정할 때 "전체 폭"이 아니라 이 폭을 기준으로
    삼아야, 최종 타일 하나가 MAX_PIXELS_PER_TILE 예산에 맞는다."""
    if COLUMN_SPLIT_COUNT <= 1 or w < MIN_WIDTH_FOR_COLUMN_SPLIT:
        return w
    return int(round(w * COLUMN_SPLIT_WIDTH_RATIO))


def split_into_tiles(im: Image.Image) -> list[Image.Image]:
    """세로로 매우 긴 이미지를 겹치는 구간을 둔 여러 조각으로 자른다. 절단 위치는 고정 간격이
    아니라, 목표 지점 근처(이전 구간)에서 가장 활동도가 낮은(텍스트/그래프가 없는 여백) 행을
    찾아 그 행에서 자른다 - 텍스트나 타임테이블 막대 한가운데가 그대로 잘리는 것을 피하기 위함.

    타일 개수 자체는 더 이상 여기서 제한하지 않는다(예전엔 한 요청에 전부 넣어야 해서 개수를
    MAX_TILES로 눌러야 했음) - 타일이 아무리 많아져도 _group_into_batches가 토큰 예산/개수
    상한 안에서 여러 요청으로 나눠 보내므로, 여기서는 그냥 MAX_PIXELS_PER_TILE/TILE_OVERLAP_PX
    기준으로 일관되게 작게 자르기만 한다.

    2026-09-07: 세로로 자른 각 띠를 다시 가로로 나누고(_split_columns, 조각 수는 COLUMN_SPLIT_COUNT),
    마지막에 최종 타일을 RENDER_TARGET_PIXELS까지 확대한다(_upscale_to_budget). 순서가 중요하다 - 자르기는
    원본 좌표로 해야 절단 위치 탐색(_find_cut_row)이 정확하고, 확대는 보낼 직전에 해야 확대된
    픽셀을 기준으로 또 자르는 낭비가 없다. 반환 순서는 띠마다 [왼쪽 ... 오른쪽]으로 끼워 넣어
    위에서 아래로 읽는 순서를 유지한다(한 배치 안에서 좌우가 인접하게 놓여, 날짜별 2열
    라인업처럼 좌우를 나란히 봐야 하는 레이아웃도 같은 요청에 들어간다)."""
    w, h = im.size
    col_w = _column_tile_width(w)
    # 좌우 조각이 높이 그대로 예산 안이면 세로로 자를 필요가 없다(아래 경로로 가도 띠가 하나라 결과는
    # 같고, 행 활동도 계산만 건너뛴다). 2026-09-25: 세로/가로 비율 조건(TALL_IMAGE_RATIO)은 이 픽셀 조건에
    # 가려져 결과에 영향이 없어 뺐다.
    if col_w * h <= MAX_PIXELS_PER_TILE:
        return [_upscale_to_budget(t) for t in _split_columns(im)]

    tile_h = max(200, MAX_PIXELS_PER_TILE // col_w)
    tiles: list[Image.Image] = []
    for top, bottom in _band_coords(_row_activity(im), 0, h, tile_h, TILE_OVERLAP_PX):
        tiles.extend(_upscale_to_budget(col) for col in _split_columns(im.crop((0, top, w, bottom))))
    return tiles


# ── 시간표 구간 (2026-09-25, extract_from_timetable.py에서 옮김) ────────────────
# 격자형 시간표는 좌우로 자른 타일로는 시각을 거의 못 읽는다(사운드플래닛 정답 확보 0/68, 그랜드민트
# 1/33). 예전에는 "grid"로 답한 배치 구간을 자동으로 찾아 전체 폭 400px 높이로 다시 잘랐지만, 이제 구간은
# 호출하는 쪽이 세로 범위로 준다. 구간은 좌우로 자르지 않고 전체 폭으로 잘라 단색 여백을 뗀 뒤 조각
# 1장씩 보낸다 - 격자형 표를 가로로 자르면 아래 조각에 무대/날짜 머리글이 빠지므로 되도록 한 장으로 보낸다.
# 모델에 보내는 조각 1장의 최대 픽셀 수. 서버의 --mm-processor-kwargs max_pixels(3_000_000)보다 작게 둔다.
TIMETABLE_MAX_PIXELS = 2_500_000
# 구간이 TIMETABLE_MAX_PIXELS를 넘으면 축소하지 않고 전체 폭 그대로 세로로 나눈다(2026-09-25 - 예전
# extract_from_timetable.py는 축소했다). 나눈 조각끼리 이만큼 겹쳐, 경계에 걸친 블록이 최소 한 조각에는
# 온전히 담기게 한다. 머리글이 안 보이는 아래 조각의 날짜는 _merge_results가 lineup의 날짜로 채운다.
TIMETABLE_SPLIT_OVERLAP_PX = 300
# 한 열(또는 행)의 픽셀 표준편차가 이 값 이하면 "단색 여백"으로 본다(JPEG 노이즈 여유 포함).
MARGIN_STD_THRESHOLD = 6.0
# 여백을 잘라낼 때 내용 가장자리에 남겨두는 여유(px) - 테두리 선/글자 끝이 딱 붙어 잘리지 않게.
MARGIN_PAD_PX = 12


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


def fit_to_pixel_budget(im: Image.Image, max_pixels: int = TIMETABLE_MAX_PIXELS) -> Image.Image:
    """픽셀 수가 max_pixels를 넘으면 가로세로 비율을 유지한 채 축소한다. 작은 이미지는 키우지 않는다."""
    w, h = im.size
    if w * h <= max_pixels:
        return im
    scale = math.sqrt(max_pixels / (w * h))
    new_size = (max(1, int(w * scale)), max(1, int(h * scale)))
    return im.resize(new_size, Image.Resampling.LANCZOS)


def split_timetable_region(im: Image.Image, top: int, bottom: int) -> list[Image.Image]:
    """원본 이미지의 [top, bottom) 세로 구간을 전체 폭으로 잘라 여백을 떼고, 모델에 1장씩 보낼 조각들로
    돌려준다. TIMETABLE_MAX_PIXELS 안이면 1장, 넘으면 폭은 그대로 두고 세로로 나눈다(절단선은 상세페이지
    타일과 같은 _band_coords로 여백 줄을 고른다). 폭만으로 예산을 넘는 극단적인 경우에만 축소한다."""
    w, h = im.size
    top, bottom = max(0, top), min(h, bottom)
    if bottom <= top:
        return []
    region = trim_margins(im.crop((0, top, w, bottom)))
    rw, rh = region.size
    if rw * rh <= TIMETABLE_MAX_PIXELS:
        return [region]
    piece_h = max(200, TIMETABLE_MAX_PIXELS // rw)
    overlap = min(TIMETABLE_SPLIT_OVERLAP_PX, piece_h // 2)
    bands = _band_coords(_row_activity(region), 0, rh, piece_h, overlap)
    return [fit_to_pixel_budget(region.crop((0, t, rw, b))) for t, b in bands]


def _estimate_tile_tokens(im: Image.Image) -> int:
    """타일 하나가 vLLM에 보낼 비전 토큰 수 근사치 (Qwen2.5-VL 28x28px 병합 패치 기준)."""
    w, h = im.size
    return max(1, int(w * h * TOKENS_PER_PIXEL))


def group_into_batches(tiles: list[Image.Image]) -> list[list[Image.Image]]:
    """타일들을 이미지 토큰 예산(IMAGE_TOKEN_BUDGET_PER_REQUEST)과 개수 상한
    (MAX_TILES_PER_BATCH) 안에서 여러 배치로 묶는다. 배치 경계에는 직전 배치의 마지막 타일을
    다음 배치 맨 앞에 다시 넣어(BATCH_OVERLAP_TILES) 요청이 나뉘는 지점에서 항목이 잘려
    유실되는 것을 막는다."""
    batches: list[list[Image.Image]] = []
    current: list[Image.Image] = []
    current_tokens = 0
    for tile in tiles:
        tokens = _estimate_tile_tokens(tile)
        if current and (
            current_tokens + tokens > IMAGE_TOKEN_BUDGET_PER_REQUEST or len(current) >= MAX_TILES_PER_BATCH
        ):
            batches.append(current)
            current = current[-BATCH_OVERLAP_TILES:] if BATCH_OVERLAP_TILES else []
            current_tokens = sum(_estimate_tile_tokens(t) for t in current)
        current.append(tile)
        current_tokens += tokens
    if current:
        batches.append(current)
    return batches


def image_to_data_uri(im: Image.Image) -> str:
    buf = io.BytesIO()
    im.save(buf, format="PNG")
    data = base64.b64encode(buf.getvalue()).decode("utf-8")
    return f"data:image/png;base64,{data}"


# ── 배치(조각) 결과 병합 ──────────────────────────────────────────────
# 여러 배치 요청 결과를 하나의 POSTER_INFO_SCHEMA 형태로 합친다. 배치가 1개뿐인 경우도 항상
# 이 경로를 거치게 해서, 모델이 한 번의 응답 안에서 같은 항목을 중복 생성하는 경우까지
# 걸러낸다("라인업 중복" 문제).

# lineup에 아티스트 대신 좌석 등급/이용권 종류명이 섞여 들어오는 게 실측으로 확인됐다(예:
# "R석", "스탠딩", "양일권") - 가격표(ticket_prices) 섹션 근처 텍스트를 아티스트명으로 착각한
# 것으로 보인다. ticket_prices의 실제 seat_type과 겹치는 이름은 정확히 걸러낼 수 있지만, 그
# 배치가 가격표를 못 봤거나 이미지에 가격표 자체가 없는 경우까지 대비해 흔한 좌석/이용권
# 명칭 패턴도 보조로 걸러낸다.
_SEAT_OR_PASS_NAME_RE = re.compile(
    r"^(R|S|A|B|VIP|프리미엄|일반|지정|스탠딩|플로어)석$"
    r"|^(양일|일일|이틀|삼일|전일|단일|종일|\d+일)권$"
    r"|^(얼리버드|프레스티지|스탠딩)$"
)

# 실사용 결과 검수(2026-09-02)에서 seat/pass명 말고도 lineup에 자주 섞여 들어오는 "사람이 아닌"
# 이름 패턴이 추가로 확인됐다 - 프롬프트에 하지 말라고 적어도(POSTER_SYSTEM_PROMPT) 소형 모델이 자주
# 안 지켜서, seat/pass명과 같은 방식으로 코드 레벨에서도 걸러낸다:
#   1. 할인/입장 대상 구분(요금 카테고리이지 사람이 아님) - "장애인", "국가유공자", "외국인" 등이
#      timetable에 공연 아티스트처럼 특정 시각과 함께 등장한 사례가 있었다.
#   2. 무대(stage) 이름 - "KB Kookmin Card Stage", "Sunset Forest Stage"처럼 timetable의 stage
#      필드에 들어가야 할 값이 artist 자리에 들어온 사례. timetable에서 실제로 관측된 stage 값과
#      겹치는 이름(정확 일치, _merge_results에서 전달)과, 그게 없어도 "Stage/스테이지/무대"로
#      끝나는 흔한 패턴을 보조로 같이 본다.
#   3. 예매처/티켓 플랫폼 이름 - 참여 venue/스폰서 로고와 비슷한 자리에 나열돼 아티스트로
#      착각되는 경우(예: "ticketlink"). 정확히 일치하는 알려진 예매처명만 보수적으로 걸러낸다
#      (동명이인 아티스트를 오탈락시키지 않기 위해 접두/접미 매칭이 아닌 완전 일치만 본다).
_ADMISSION_CATEGORY_RE = re.compile(
    r"^(장애인|국가유공자|국가보훈대상자|보훈대상자|외국인|경로우대|다자녀|다자녀가정)"
    r"(\s*\(?(본인만?|본인|동반\d*인?|우대|중증|경증)\)?)*$"
)
_STAGE_SUFFIX_RE = re.compile(r"(Stage|STAGE|스테이지|무대)$")
_TICKETING_PLATFORM_NAMES = {
    "ticketlink", "티켓링크", "interpark", "인터파크", "인터파크티켓",
    "yes24", "예스24", "yes24티켓", "melon", "멜론", "멜론티켓",
    "nol", "yanolja", "야놀자", "nol티켓", "kopis", "코피스",
}


# 2026-09-07 추가: POSTER_SYSTEM_PROMPT를 "먼저 인원 수를 세고(lineup_artist_count) 그 수만큼 채운다"는
# 절차로 바꾸면서, 개수를 맞추려고 모델이 없는 이름을 지어낼 위험이 새로 생겼다(프롬프트 3단계에서
# 명시적으로 금지하지만, 소형 모델이 지시를 안 지키는 건 이 파일 전반에서 이미 확인된 패턴이라
# seat/stage 이름과 같은 방식으로 코드에서도 한 번 더 막는다). 실제 아티스트명과 겹칠 여지가
# 거의 없는 자리표시자/미공개 표시만 보수적으로 걸러낸다.
#
# 2026-09-13 추가: 이름이 안 보이는 구간에서도 모델이 lineup을 채우려 하면서, 프롬프트 예시 이름을
# 그대로 베끼는 것이 실측으로 확인됐다(결과 34개 중 19개 - "C JAMM"/"Black Nut"/"Sunset Forest
# Stage"/"가수A"에서 온 "A","B" 등). 예시를 빼면 "Artist A"/"Various Artists"/한 글자 이름으로
# 바뀔 뿐 지어내기 자체는 계속됐다. 그래서 프롬프트 예시를 전부 꺾쇠(〈아티스트1〉, 〈무대1〉)
# 자리표시자로 바꾸고, 꺾쇠가 들어간 값은 여기서 무조건 걸러낸다 - 실제 이름을 차단 목록에 넣으면
# 그 아티스트가 진짜 출연하는 공연에서 오탈락하기 때문. 한 글자 이름, "Various Artists", 라인업
# 미공개 표시("Blind Ticket")도 같이 걸러낸다.
_PLACEHOLDER_ARTIST_RE = re.compile(
    r"^(가수|아티스트|출연자|아티스트명|artist|performer)\s*[A-Za-z0-9]?$"
    r"|^(TBA|TBD|N/?A|미정|추후\s*공개|추후공지|coming\s*soon|and\s*more|앤\s*모어)$"
    r"|^\?+$"
    r"|^[A-Za-z]$"
    r"|^various\s*artists?$"
    r"|^(blind\s*ticket|블라인드\s*티켓|early\s*bird(\s*ticket)?|얼리버드\s*티켓)$",
    re.IGNORECASE,
)
# 프롬프트 예시용 꺾쇠 자리표시자. 모델이 ASCII 부등호로 바꿔 쓰는 경우까지 본다.
_PROMPT_PLACEHOLDER_RE = re.compile(r"[〈〉<>]")

# 2026-09-13: 게이트 오픈 같은 입장 안내 항목은 timetable의 artist에 인쇄된 문구 그대로 들어온다
# (timetable에 항목 종류 필드를 두지 않기로 함). 아티스트 이름이 아니므로 timetable에서는 lineup
# 필터를 거치지 않게 따로 모으고, lineup에 섞여 들어오면 걸러낸다.
_ADMISSION_NOTICE_RE = re.compile(
    r"(gate|doors?)\s*open|게이트\s*오픈|입장|ticket\s*booth|티켓\s*부스|매표소|box\s*office|팔찌\s*교환|wristband",
    re.IGNORECASE,
)


def _looks_like_admission_notice(name: str) -> bool:
    return bool(_ADMISSION_NOTICE_RE.search(name))


def _looks_like_placeholder_artist(name: str) -> bool:
    stripped = name.strip()
    return bool(_PLACEHOLDER_ARTIST_RE.match(stripped) or _PROMPT_PLACEHOLDER_RE.search(stripped))


def _looks_like_seat_or_pass_name(name: str) -> bool:
    return bool(_SEAT_OR_PASS_NAME_RE.match(name.strip()))


def _looks_like_admission_category(name: str) -> bool:
    return bool(_ADMISSION_CATEGORY_RE.match(name.strip()))


def _looks_like_stage_name(name: str, stage_names: set[str]) -> bool:
    stripped = name.strip()
    return stripped in stage_names or bool(_STAGE_SUFFIX_RE.search(stripped))


def _looks_like_ticketing_platform(name: str) -> bool:
    return name.strip().lower() in _TICKETING_PLATFORM_NAMES


def _filter_lineup_noise(entries: list[dict], seat_type_names: set[str], stage_names: set[str]) -> list[dict]:
    """lineup에서 (1) 실제로는 좌석 등급/이용권/할인구분/무대명/예매처명이거나 모델이 인원 수를
    맞추려고 지어낸 자리표시자("가수A", "TBA")인 "사람이 아닌" 항목과
    (2) 실제로 이름이 있는 항목이 하나라도 있을 때 같이 섞여 들어온 artist=null "빈" 항목을
    제거한다(진짜 블라인드 라인업이면 애초에 실제 이름 항목이 하나도 없을 것이므로 null 항목이
    그대로 남는다). 마스코트 캐릭터명·행사 제목처럼 규칙화하기 어려운 오분류는 여기서 못 잡으니
    POSTER_SYSTEM_PROMPT의 명시적 예시로만 대응한다."""
    has_named = any(e.get("artist") for e in entries)
    result = []
    for e in entries:
        name = e.get("artist")
        if name is None:
            if has_named:
                continue
        elif (
            name.strip() in seat_type_names
            or _looks_like_seat_or_pass_name(name)
            or _looks_like_admission_category(name)
            or _looks_like_stage_name(name, stage_names)
            or _looks_like_ticketing_platform(name)
            or _looks_like_placeholder_artist(name)
            or _looks_like_admission_notice(name)
        ):
            continue
        result.append(e)
    return result


def _artist_key(name: str) -> str:
    """같은 아티스트의 표기 차이를 무시하고 비교하기 위한 키(2026-09-13). 대소문자, 공백,
    기호, 괄호 속 보조 표기를 무시한다 - "Young K(DAY6)" = "Young K (DAY6)", "김창완 밴드" =
    "김창완밴드", "UVERworld (JP)" = "UVERworld". 표시용 이름은 바꾸지 않고 비교에만 쓴다.
    국문/영문처럼 문자 체계가 다른 표기는 합치지 않는다(백엔드에서 처리)."""
    folded = name.casefold()
    key = re.sub(r"[\W_]+", "", re.sub(r"\([^)]*\)", "", folded))
    return key or re.sub(r"[\W_]+", "", folded) or folded.strip()


def _dedupe_lineup(entries: list[dict]) -> list[dict]:
    """(artist, performance_date) 조합이 같은 항목은 한 번만 남긴다. 같은 아티스트가 한
    조각에서는 날짜 헤더를 못 봐서 null로, 다른 조각에서는 날짜까지 보여서 채워진 채로 나온
    경우 - null 쪽 항목은 버리고 날짜가 채워진 항목만 남긴다(둘 다 남기면 같은 아티스트가
    날짜 없는 항목과 날짜 있는 항목으로 중복 집계됨).

    2026-09-13: 이름 비교를 _artist_key로 한다. 먼저 나온 표기가 남으므로, 호출부가 라인업 구역
    배치의 항목을 앞에 두면 그쪽 표기가 우선한다. 또 합동 표기("A x B")는 구성원이 모두 개별
    항목으로 따로 있으면 버린다(라인업 구역과 시간표 이름을 합칠 때 시간표 쪽 묶음 표기가 한
    팀처럼 끼어들지 않게)."""
    single_keys = {
        _artist_key(e["artist"]) for e in entries if e.get("artist") and len(_split_collab_name(e["artist"])) == 1
    }
    dated_keys: set[str] = {
        _artist_key(e["artist"]) for e in entries if e.get("artist") and e.get("performance_date")
    }

    seen: set[tuple] = set()
    result: list[dict] = []
    for e in entries:
        name, date = e.get("artist"), e.get("performance_date")
        name_key = _artist_key(name) if name else None
        if name:
            parts = _split_collab_name(name)
            if len(parts) > 1 and all(_artist_key(p) in single_keys for p in parts):
                continue
        if name and date is None and name_key in dated_keys:
            continue
        key = (name_key, date)
        if key in seen:
            continue
        seen.add(key)
        result.append({"artist": name, "performance_date": date})
    return result


def _dedupe_timetable(entries: list[dict], artist_dates: dict[str, set[str]]) -> list[dict]:
    """timetable 항목을 합치면서 (1) 날짜가 비어 있는 항목은 lineup에서 그 아티스트의 날짜가
    단 하나로 특정될 때만 그 날짜로 채우고(모호하면 추측하지 않고 null 유지), (2)
    (artist, performance_date, time, stage) 완전 중복을 제거한다."""
    filled: list[dict] = []
    for e in entries:
        entry = dict(e)
        name = entry.get("artist")
        if entry.get("performance_date") is None and name:
            candidates = artist_dates.get(_artist_key(name))
            if candidates is None:
                # 합동 표기("A x B")는 lineup에 그 이름 그대로는 없다 - 구성원들의 날짜가
                # 하나로 일치할 때만 그 날짜로 채운다.
                parts = _split_collab_name(name)
                if len(parts) > 1:
                    part_dates = [artist_dates.get(_artist_key(p)) for p in parts]
                    if all(part_dates):
                        union = set().union(*part_dates)
                        candidates = union if len(union) == 1 else None
            if candidates and len(candidates) == 1:
                entry["performance_date"] = next(iter(candidates))
        filled.append(entry)

    seen: set[tuple] = set()
    result: list[dict] = []
    for e in filled:
        key = (e.get("artist"), e.get("performance_date"), e.get("time"), e.get("stage"))
        if key in seen:
            continue
        seen.add(key)
        result.append(e)
    return result


def _dedupe_ticket_prices(entries: list[dict]) -> list[dict]:
    """seat_type이 같은 항목은 먼저 나온 것만 남긴다(같은 가격표가 그리드+텍스트 이중 표기
    등으로 여러 조각에 걸쳐 반복 등장하는 경우 대비)."""
    seen: set[str] = set()
    result: list[dict] = []
    for e in entries:
        seat = e.get("seat_type")
        if seat in seen:
            continue
        seen.add(seat)
        result.append(e)
    return result


def _pick_majority(values: list) -> object | None:
    """서로 다른 배치가 낸 후보 중 가장 많이 반복된(=인접 배치들이 겹치는 구간에서 동일하게
    확인한) 값을 채택한다. 동표면 먼저 등장한 값을 쓴다. 스칼라 필드(ticket_delivery_date 등)
    전반에 재사용."""
    non_null = [v for v in values if v is not None]
    if not non_null:
        return None
    counts = Counter(non_null)
    top_count = max(counts.values())
    for v in non_null:  # 첫 등장 순서 유지
        if counts[v] == top_count:
            return v
    return None  # pragma: no cover - non_null이 비어있지 않으면 도달하지 않음


def _pick_ticketing_date(results: list[dict], performance_dates: set[str]) -> str | None:
    """배치마다 ticketing_date를 독립적으로 답하다 보니, 어떤 조각은 "공연시간 안내"처럼
    공연 당일 날짜가 적힌 구간만 보고 그걸 예매 오픈일로 착각해 답하는 경우가 있었다(실제
    "판매시작 OOOO-OO-OO"는 페이지 더 아래 다른 조각에 있는데, 그 조각이 먼저 처리돼 잘못된
    값이 그냥 채택돼 버림 - "먼저 나온 값 채택" 방식으로 실제 테스트해보니 이 실패가 재현됨).

    "가장 많이 겹쳐서 같은 값이 반복 확인된 후보"를 쓰는 다수결 방식으로 바꿨다 - 진짜 정답은
    타일 겹침 덕에 인접한 여러 배치가 같은 값을 볼 가능성이 높고, 착각한 오답은 보통 그 착각을
    유발한 배치 하나에서만 나온다(실제로 이 방식으로 재현 테스트했을 때 정답 2표 vs 오답 1표로
    정답이 이겼다). performance_dates(라인업/타임테이블에 등장하는 실제 공연일)와 우연히 같은
    값은 동표일 때만 후순위로 미루는 2차 기준으로 쓴다(1차로 쓰면 timetable에 잘못 섞여든
    항목 때문에 함께 오염될 수 있어 신뢰도가 더 낮다)."""
    candidates = [r["ticketing_date"] for r in results if r.get("ticketing_date")]
    if not candidates:
        return None
    counts = Counter(candidates)
    top_count = max(counts.values())
    top_candidates = [c for c in dict.fromkeys(candidates) if counts[c] == top_count]  # 첫 등장 순서 유지
    if len(top_candidates) == 1:
        return top_candidates[0]
    non_performance = [c for c in top_candidates if c not in performance_dates]
    return non_performance[0] if non_performance else top_candidates[0]


def _pick_delivery_date(results: list[dict]) -> str | None:
    return _pick_majority([r.get("ticket_delivery_date") for r in results])


# 합동 공연 표기: 타임테이블은 한 칸(=한 공연)에 여러 아티스트를 묶어 쓰는 반면, 라인업 구역은
# 같은 사람들을 개별 이름표로 따로 적는 경우가 많다(실측: 타임테이블 "C JAMM x Black Nut" /
# 라인업 "C JAMM", "Black Nut"). lineup ⊇ timetable.artists를 글자 그대로 강제하면 이런 정상적인
# 타임테이블 항목이 통째로 지워지므로, 이름을 비교하기 전에 이 구분자로 분해해서 판정한다.
# timetable에는 합친 원래 표기를 그대로 남긴다(한 칸에서 함께 공연한다는 정보이므로).
_COLLAB_SPLIT_RE = re.compile(r"\s+(?:x|X|×|with|WITH|&|vs\.?|VS\.?)\s+")


def _split_collab_name(name: str) -> list[str]:
    """합동 공연 표기를 개별 아티스트 이름으로 분해한다. 구분자가 없으면 원래 이름 하나만
    담긴 리스트를 돌려준다. 구분자를 공백으로 감싼 형태만 본다 - "SiK-K"의 하이픈이나
    "015B"처럼 이름 안에 붙어 있는 글자를 잘못 쪼개지 않기 위함."""
    parts = [p.strip() for p in _COLLAB_SPLIT_RE.split(name.strip()) if p.strip()]
    return parts if len(parts) > 1 else [name.strip()]


def _timetable_name_matches_lineup(name: str, lineup_keys: set[str]) -> bool:
    """timetable의 artist가 lineup으로 설명되는지 판정한다. 이름이 lineup에 있거나, 합동 표기를
    분해했을 때 구성원이 "전부" lineup에 있으면 정상으로 본다. lineup_keys는 _artist_key 값이라
    표기 차이("Young K(DAY6)" / "Young K (DAY6)")로 정상 항목이 지워지지 않는다."""
    stripped = name.strip()
    if _artist_key(stripped) in lineup_keys:
        return True
    parts = _split_collab_name(stripped)
    return len(parts) > 1 and all(_artist_key(p) in lineup_keys for p in parts)


def _filter_timetable_to_lineup(timetable: list[dict], lineup_keys: set[str]) -> list[dict]:
    """timetable의 artist는 반드시 lineup에 있는 이름과 같아야 한다(POSTER_SYSTEM_PROMPT 지시) - 하지만
    프롬프트만으로는 안 지켜지는 경우가 실측으로 확인됐다(부스/구역 코드 "N21","S6" 같은,
    lineup에 전혀 없는 이름이 timetable에 섞여 나옴). lineup을 먼저 확정한 뒤 여기서 lineup에
    없는 이름의 timetable 항목을 강제로 제거해 - 모델이 지시를 안 지켜도 결과가 항상
    lineup ⊇ timetable.artists를 만족하게 코드 레벨에서 보장한다.

    2026-09-07: 합동 공연 표기(_split_collab_name)는 예외로 둔다. 라인업을 제대로 뽑을수록
    "C JAMM x Black Nut" 같은 정상 항목이 오히려 지워지는 역효과가 나기 때문이다."""
    return [e for e in timetable if e.get("artist") and _timetable_name_matches_lineup(e["artist"], lineup_keys)]


def _warn_if_undercounted(results: list[dict]) -> None:
    """배치가 스스로 센 아티스트 수(lineup_artist_count)보다 실제로 나열한 lineup 항목이 적으면
    stderr에 한 줄 남긴다. 개수를 먼저 세게 한 목적 자체가 "훑다 말고 뒷부분을 빠뜨리는" 누락을
    줄이는 것이므로, 그래도 덜 채운 배치가 있으면 그게 바로 누락 의심 지점이다 - 결과를 바꾸지는
    않고(모델이 센 개수 쪽이 틀렸을 수도 있으므로) 어떤 이미지를 다시 봐야 하는지만 알린다.
    배치별로 비교한다 - 타일이 겹쳐 있어 배치 간 합계는 서로 중복되므로 더하면 의미가 없다."""
    for i, r in enumerate(results):
        expected = r.get("lineup_artist_count")
        if not expected:
            continue
        actual = len([e for e in (r.get("lineup") or []) if e.get("artist")])
        if actual < expected:
            print(
                f"[경고] 배치 {i + 1}: 모델이 센 아티스트 수 {expected}명보다 실제 추출이 "
                f"{actual}명으로 적습니다 (누락 의심).",
                file=sys.stderr,
            )


# ── 병합 전후 보정 (2026-09-14) ─────────────────────────────────────────
_DATE_YEAR_RE = re.compile(r"^(20\d{2})(-\d{2}-\d{2})$")
# 페이지 연도를 읽을 맨 위 배치 수. 예매처 상세페이지는 맨 위에 "공연기간 2024.10.26 ~ 2024.11.03"처럼
# 연도가 인쇄된 기간을 적어서, 맨 위 배치들은 연도를 지어낼 필요 없이 실제 연도를 낸다(실측: 그랜드민트·
# 펜타포트·사운드플래닛 모두 첫 3개 배치의 날짜 연도가 전부 정답). 첫 배치에 날짜가 1개뿐인 경우도 있어
# (펜타포트) 3개를 본다.
PAGE_YEAR_TOP_BATCHES = 3
# 시간표 구간 프롬프트(TIMETABLE_SYSTEM_PROMPT)가 "연도가 이미지에 없으면 쓰라"고 한 자리표시자 연도.
# 페이지 연도를 정할 때는 세지 않고, _normalize_years가 페이지 연도로 바꾼다(2년 이상 차이 나므로).
# 페이지 연도를 못 정하면(--timetable-crop처럼 연도가 보이는 곳이 없으면) 그대로 남는다.
UNKNOWN_YEAR = 2000


def _date_years(result: dict, include_ticket_dates: bool) -> list[int]:
    dates = [e.get("performance_date") for e in (result.get("lineup") or []) + (result.get("timetable") or [])]
    if include_ticket_dates:
        dates += [result.get("ticketing_date"), result.get("ticket_delivery_date")]
    years = [int(m.group(1)) for d in dates if (m := _DATE_YEAR_RE.match(d or ""))]
    return [y for y in years if y != UNKNOWN_YEAR]


def _normalize_years(results: list[dict]) -> list[dict]:
    """조각에 연도가 안 보이면 모델이 연도를 지어내는데(펜타포트 실측: 8월 1일 시간표 전체가
    2023-08-01로 나옴), 이런 날짜를 페이지 연도로 바로잡는다. 페이지 연도와 2년 이상 차이 나는 날짜만
    바꾼다 - 연말~연초에 걸친 공연이나 전년도에 예매가 열리는 경우(1년 차이)는 그대로 둔다. 바꾼
    날짜가 달력에 없으면(2월 29일 등) 원래 값을 둔다.

    페이지 연도는 맨 위 PAGE_YEAR_TOP_BATCHES개 배치가 낸 날짜(공연 날짜와 예매일·배송일 전부)에서
    가장 많이 나온 연도다. results는 배치 순서(페이지 위에서 아래)대로 들어온다. 처음에는 "전체 배치
    날짜 중 최근 연도 우선"으로 정했는데, 지어낸 연도가 거의 항상 2023이라 2021년 이전의 옛날 페이지를
    처리하면 진짜 날짜가 2023으로 바뀔 수 있었다(사운드플래닛 실측: 2026이 214개, 지어낸 2023이
    195개). 맨 위 배치들에 날짜가 하나도 없을 때만 그 규칙으로 돌아간다."""
    top_years = Counter(y for r in results[:PAGE_YEAR_TOP_BATCHES] for y in _date_years(r, include_ticket_dates=True))
    if top_years:
        page_year = top_years.most_common(1)[0][0]
    else:
        years = Counter(y for r in results for y in _date_years(r, include_ticket_dates=False))
        if not years:
            return results
        top = max(years.values())
        page_year = max(y for y, c in years.items() if c >= top * 0.25)

    def fix(date: str | None) -> str | None:
        m = _DATE_YEAR_RE.match(date or "")
        if not m or abs(int(m.group(1)) - page_year) < 2:
            return date
        candidate = f"{page_year}{m.group(2)}"
        try:
            datetime.strptime(candidate, "%Y-%m-%d")
        except ValueError:
            return date
        return candidate

    fixed = []
    for r in results:
        r = dict(r)
        r["lineup"] = [{**e, "performance_date": fix(e.get("performance_date"))} for e in (r.get("lineup") or [])]
        if r.get("timetable") is not None:
            r["timetable"] = [{**e, "performance_date": fix(e.get("performance_date"))} for e in r["timetable"]]
        r["ticketing_date"] = fix(r.get("ticketing_date"))
        r["ticket_delivery_date"] = fix(r.get("ticket_delivery_date"))
        fixed.append(r)
    return fixed


def _one_slot_per_artist_day(timetable: list[dict], raw_entries: list[dict]) -> list[dict]:
    """페스티벌에서 같은 아티스트가 같은 날 여러 (시각, 무대)로 나오면 가장 많은 배치가 낸 것 하나만
    남긴다(동률이면 먼저 나온 것). 펜타포트 실측에서 한 무대의 시간표 목록이 다른 무대 두 곳에 통째로
    복사되거나, 다른 무대 아티스트에게 일정 간격의 가짜 시각이 붙거나, 같은 아티스트가 한 무대에
    7번 반복되는 실패가 있었는데, 실제 공연은 하루 한 번이라 모두 이 규칙으로 걸러진다. 날짜가
    채워진 항목이 있는 아티스트의 날짜 없는 항목도 버린다. 하루에 두 번 서는 경우(워크숍+공연 등)는
    하나를 잃을 수 있다."""
    support: Counter = Counter(
        (_artist_key(e["artist"]), e.get("performance_date"), e.get("time"), e.get("stage"))
        for e in raw_entries
        if e.get("artist")
    )
    dated_artists = {_artist_key(e["artist"]) for e in timetable if e.get("artist") and e.get("performance_date")}
    best: dict[tuple, tuple[int, dict]] = {}
    for e in timetable:
        key = _artist_key(e["artist"])
        date = e.get("performance_date")
        if date is None and key in dated_artists:
            continue
        score = support[(key, date, e.get("time"), e.get("stage"))]
        if date is not None:
            score += support[(key, None, e.get("time"), e.get("stage"))]
        group = (key, date)
        if group not in best or score > best[group][0]:
            best[group] = (score, e)
    kept_ids = {id(entry) for _, entry in best.values()}
    return [e for e in timetable if id(e) in kept_ids]


# ── 시간표 구간 결과 정리 (2026-09-25, extract_from_timetable.py에서 옮김) ────────
# 무대 이름이 아닌 stage 값. null로 바꾼다.
#   - 모델이 지어내는 자리표시자("무대1", "Stage 1", 꺾쇠 표기)
#   - 한 글자("A", "B" - allfamily 실측)
#   - 날짜 헤더를 무대로 옮긴 값("10.31토" - sbmf 실측)
_PLACEHOLDER_STAGE_RE = re.compile(
    r"^\s*(무대|스테이지|stage)\s*\d*\s*$|[〈〉<>]|^\s*\S\s*$|\d{1,2}\s*[./]\s*\d{1,2}",
    re.IGNORECASE,
)


def _clean_timetable(entries: list[dict]) -> list[dict]:
    """구간 조각 하나의 timetable 항목을 정리한다: 자리표시자 무대 이름을 null로 바꾸고, 이름이나 시각이
    없는 항목은 버리고, (날짜, 시각, 이름)이 같은 항목은 첫 번째만 남긴다 - 모델이 같은 이름을 무대만
    바꿔가며 반복 생성하는 루프(gmf2025 실측: "Dragon Pony" 60회)를 걷어내기 위함."""
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
        if not artist or not e.get("time"):
            continue
        key = (e.get("performance_date"), e["time"], artist.casefold())
        if key in seen:
            continue
        seen.add(key)
        cleaned.append({
            "performance_date": e.get("performance_date"),
            "time": e["time"],
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


def _timetable_region_result(raw: dict) -> dict:
    """구간 조각 하나의 모델 응답(POSTER_INFO_SCHEMA)을 _merge_results에 넘길 형태로 정리한다. timetable은
    _clean_timetable로 거르고, lineup은 모델 답 대신 그 timetable에서 만든다. 시간표 이미지에는 티켓/배송/
    가격/음식물 정보가 없으므로 그 필드는 모델 답과 상관없이 null로 둔다 - 배치 다수결로 정하는 필드라
    잘못 읽은 값이 끼어들지 않게."""
    timetable = _clean_timetable(raw.get("timetable") or [])
    return {
        **raw,
        "lineup": _lineup_from_timetable(timetable),
        "timetable": timetable,
        "ticketing_date": None,
        "ticket_delivery_date": None,
        "ticket_prices": None,
        "other_info": {"food_allowed": None},
    }


def _artist_timetable_entries(results: list[dict]) -> list[dict]:
    """results의 timetable 항목 중 입장 안내(GATE OPEN 등)를 뺀 아티스트 항목."""
    return [
        e
        for r in results
        for e in (r.get("timetable") or [])
        if not (e.get("artist") and _looks_like_admission_notice(e["artist"]))
    ]


def _merge_results(results: list[dict], timetable_results: list[dict] | None = None) -> dict:
    """타일 배치 결과(results)와 시간표 구간 조각 결과(timetable_results, _timetable_region_result로 정리한
    것)를 백엔드 계약 6키 결과로 합친다. timetable_results가 None이면 시간표 구간이 주어지지 않은 것이고,
    []이면 구간은 주어졌지만 읽어낸 조각이 없는 것이다."""
    # 병합 전 보정(2026-09-14): 지어낸 연도를 페이지 연도로 바로잡는다. 구간 결과도 같이 보정한다 - 구간
    # 프롬프트는 연도가 안 보이면 UNKNOWN_YEAR를 쓴다. 구간 결과를 뒤에 붙이므로 페이지 연도는 그대로 맨 위
    # 타일 배치들이 정한다.
    n_tile_results = len(results)
    corrected = _normalize_years(results + (timetable_results or []))
    results, region_results = corrected[:n_tile_results], corrected[n_tile_results:]

    # ticket_prices/timetable을 먼저 합쳐서, 그 seat_type/stage 이름들을 lineup 노이즈 필터링
    # 근거로 쓴다(아래 _filter_lineup_noise) - lineup을 확정하기 전에 "아티스트가 아닌 것으로
    # 이미 확인된 이름"을 먼저 모아두는 것.
    all_prices = [e for r in results for e in (r.get("ticket_prices") or [])]
    ticket_prices = _dedupe_ticket_prices(all_prices) if all_prices else None
    seat_type_names = {e["seat_type"].strip() for e in (ticket_prices or []) if e.get("seat_type")}

    # 페스티벌/그 외 공연 구분(2026-09-13): 배치는 자기 구간만 보고 event_category를 답하므로,
    # 페스티벌 페이지라도 라인업/블라인드·얼리버드 문구가 안 보이는 구간(예: 반입 물품 안내)은
    # "other"로 답한다 - 그래서 한 배치라도 "festival"이면 페이지 전체를 페스티벌로 본다.
    # 페스티벌이면 lineup/timetable은 "festival"로 답한 배치에서만 가져온다. "other" 배치는 그 외
    # 공연 절차(공연명/상단에서 이름 읽기)를 따르므로, 페스티벌 제목 영역의 행사명을 아티스트로
    # 적었을 수 있기 때문이다. 입장 안내 항목(artist가 "GATE OPEN" 등)은 아래에서 따로 다룬다.
    # 시간표 구간 조각도 "festival"로 답했으면(여러 아티스트의 시각이 보이면) 페스티벌로 본다.
    is_festival = any(r.get("event_category") == "festival" for r in results + region_results)
    lineup_results = [r for r in results if r.get("event_category") == "festival"] if is_festival else results

    # 아티스트 시간표의 출처(2026-09-25): 시간표 구간이 주어지면 구간 결과만 쓴다 - 좌우로 자른 타일에서
    # 읽은 시간표는 격자형에서 거의 틀렸다. 구간이 없으면 페스티벌은 아티스트 시간표를 비우고(입장 안내만
    # 아래에서 남긴다), 그 외 공연은 타일에서 읽은 공연 시작 시각을 그대로 쓴다 - 단독 공연에는 따로 잘라 줄
    # 시간표가 없다. 무대 이름은 타일 시간표를 버리더라도 lineup 노이즈 필터 근거로는 계속 모은다.
    if timetable_results is not None:
        raw_timetable_entries = _artist_timetable_entries(region_results)
    elif is_festival:
        raw_timetable_entries = []
    else:
        raw_timetable_entries = _artist_timetable_entries(lineup_results)
    stage_names = {
        e["stage"].strip()
        for e in _artist_timetable_entries(lineup_results) + raw_timetable_entries
        if e.get("stage")
    }

    # 라인업 출처 우선 채택(2026-09-07): 전용 라인업 구역을 본 배치가 하나라도 있으면, 시간표
    # 칸에서만 이름을 읽은 배치의 lineup은 버린다. 실측에서 페이지에 전용 구역(43팀)이 있는데도
    # 최종 lineup이 타임테이블 유래 20팀으로 채워지고(set(lineup)-set(timetable)이 공집합),
    # 표기까지 시간표 쪽("C JAMM x Black Nut", "김창완 밴드")을 따라간 사례가 있었다. 배치마다
    # 답한 lineup_source로 이 둘을 구분할 수 있다. 전용 구역을 본 배치가 하나도 없으면 예전대로
    # 전부(=시간표 유래 포함) 쓴다 - 그게 유일한 정보원인 페이지도 실제로 많기 때문.
    # 2026-09-13 변경: 라인업 구역 배치 이름 + 시간표 배치 이름의 합집합으로 바꿨다. 사운드플래닛
    # 실측에서 라인업 구역(5개 무대 x 2일, 약 70팀)을 본 배치가 첫 무대 블록 16팀만 읽고 멈췄는데,
    # 위 규칙 때문에 시간표 배치가 제대로 읽은 나머지 팀(장범준, 어반자카파 등 약 30팀)이 통째로
    # 버려졌다. 위 사례의 문제(시간표 표기가 라인업 구역 표기를 대체)는 합집합에서도 생기지 않게,
    # 라인업 구역 배치 항목을 앞에 둬 그쪽 표기가 우선하게 하고, _dedupe_lineup이 표기 차이를
    # 무시해 비교하며 구성원이 따로 있는 합동 표기("A x B")는 버린다.
    # 2026-09-25: 시간표 구간 조각의 lineup(그 조각 timetable에서 만든 이름)은 lineup_source와 상관없이 항상
    # 합친다 - 맨 뒤에 둬서 라인업 구역 표기가 우선한다.
    section_results = [r for r in lineup_results if r.get("lineup_source") == "lineup_section"]
    timetable_source_results = [r for r in lineup_results if r.get("lineup_source") == "timetable_only"]
    source_results = section_results + timetable_source_results or lineup_results
    all_lineup = [e for r in source_results + region_results for e in (r.get("lineup") or [])]
    lineup = _dedupe_lineup(all_lineup)
    lineup = _filter_lineup_noise(lineup, seat_type_names, stage_names)
    lineup_keys = {_artist_key(e["artist"]) for e in lineup if e["artist"]}

    artist_dates: dict[str, set[str]] = {}
    for e in lineup:
        if e["artist"] and e["performance_date"]:
            artist_dates.setdefault(_artist_key(e["artist"]), set()).add(e["performance_date"])

    # 빈 결과는 맨 아래에서 null로 통일한다(2026-09-25: 예전에는 timetable_present를 보고 null과 []를
    # 여기서 구분했지만, 마지막의 `timetable or None`이 어차피 둘을 같게 만들어 뺐다).
    timetable = _dedupe_timetable(raw_timetable_entries, artist_dates)
    timetable = _filter_timetable_to_lineup(timetable, lineup_keys)
    if is_festival:
        timetable = _one_slot_per_artist_day(timetable, raw_timetable_entries)

    # 입장 안내 항목(2026-09-13): 페스티벌이면 artist가 입장 문구("GATE OPEN" 등)인 항목을 lineup
    # 필터 없이 따로 모아 앞에 붙인다. 그 외 공연은 공연 시작 시각(아티스트 이름 항목, 위에서 처리)만
    # 남기고 입장 항목은 버린다. 배치 구분 없이 전체 results에서 모은다 - 입장 시각은 흔히 라인업이
    # 안 보이는 상단 공연정보 구간에 있어서, 페스티벌 페이지라도 그 구간 배치는 "other"로 답하기
    # 때문이다. 같은 시각을 구간마다 다른 표기("GATE OPEN"/"게이트 오픈")로 적을 수 있어 (날짜, 시각,
    # 무대) 칸이 같으면 먼저 나온 것만 남기고, 날짜 헤더가 안 보여 날짜가 null로 나온 항목은 같은
    # 시각에 날짜가 채워진 항목이 있으면 버린다.
    admission_entries = [
        e
        for r in results + region_results
        for e in (r.get("timetable") or [])
        if is_festival and e.get("artist") and e.get("time") and _looks_like_admission_notice(e["artist"])
    ]
    dated_times = {e["time"] for e in admission_entries if e.get("performance_date")}
    admission_slots: set[tuple] = set()
    notices: list[dict] = []
    for e in admission_entries:
        slot = (e.get("performance_date"), e["time"], e.get("stage"))
        if (e.get("performance_date") is None and e["time"] in dated_times) or slot in admission_slots:
            continue
        admission_slots.add(slot)
        notices.append(dict(e))
    if notices:
        notices.sort(key=lambda e: (e.get("performance_date") or "", e["time"]))
        timetable = notices + (timetable or [])

    # 프롬프트 예시 자리표시자(〈무대1〉)가 무대명으로 새어 들어온 경우 무대명만 비운다 - 아티스트와
    # 시각은 실제일 수 있어 항목 자체는 남긴다. 또 lineup 필터가 지어낸 이름을 걷어내면서 그 이름에
    # 딸린 공연 항목이 전부 사라진 경우(예: 블라인드 티켓 페이지인데 일부 배치가 가짜 시간표를
    # 냄) 빈 배열 대신 null로 돌려, 시간표가 없는 페이지와 같은 결과가 되게 한다.
    if timetable:
        timetable = [
            {**e, "stage": None} if e.get("stage") and _PROMPT_PLACEHOLDER_RE.search(e["stage"]) else e
            for e in timetable
        ]
    timetable = timetable or None

    performance_dates = {e["performance_date"] for e in lineup if e["performance_date"]}
    performance_dates |= {e["performance_date"] for e in (timetable or []) if e.get("performance_date")}

    ticketing_date = _pick_ticketing_date(results, performance_dates)
    ticket_delivery_date = _pick_delivery_date(results)

    food_allowed = _pick_majority([(r.get("other_info") or {}).get("food_allowed") for r in results])

    _warn_if_undercounted(results)

    # 반환 형태는 백엔드 계약(schemas.py) 그대로인 6개 키다 - event_category/lineup_source/
    # lineup_artist_count/timetable_present는 모델이 절차를 순서대로 밟게 만들기 위한 스캐폴딩 필드일 뿐이라 여기서
    # 떨어져 나간다(normalize.py/콜백이 모르는 키가 새로 흘러가지 않게).
    return {
        "timetable": timetable,
        "lineup": lineup,
        "ticketing_date": ticketing_date,
        "ticket_delivery_date": ticket_delivery_date,
        "ticket_prices": ticket_prices,
        "other_info": {"food_allowed": food_allowed},
    }


# 두 요청(타일 배치, 시간표 구간 조각) 모두 같은 스키마로 강제 출력한다.
_POSTER_INFO_RESPONSE_FORMAT = {
    "type": "json_schema",
    "json_schema": {
        "name": "poster_info",
        "schema": POSTER_INFO_SCHEMA,
        "strict": True,
    },
}


# 숫자를 읽었을 때 받침이 있으면 "은", 없으면 "는"(일·삼·육·칠·팔 -> 은, 이·사·오·구 -> 는).
_TOPIC_PARTICLE_BY_LAST_DIGIT = {"1": "은", "2": "는", "3": "은", "4": "는", "5": "는", "6": "은", "7": "은", "8": "은", "9": "는"}


def _overlap_phrase(fraction: float) -> str:
    """이웃 조각이 겹치는 폭(원본 폭 대비)을 "3분의 1"처럼 쓴다. 분모 10 이하의 분수로 딱 떨어지지 않으면
    "약 N%"로 쓴다."""
    approx = Fraction(fraction).limit_denominator(10)
    if 0 < approx < 1 and abs(float(approx) - fraction) < 1e-6:
        return f"{approx.denominator}분의 {approx.numerator}"
    return f"약 {round(fraction * 100)}%"


def _fragment_note() -> str:
    """FRAGMENT_NOTE의 조각 설명({fragment_layout})을 COLUMN_SPLIT_COUNT/COLUMN_SPLIT_WIDTH_RATIO에 맞게
    채운다. 기본값(2개, 2/3)이면 예전 고정 문구와 한 글자도 다르지 않다."""
    if COLUMN_SPLIT_COUNT <= 1:
        return FRAGMENT_NOTE.format(fragment_layout=FRAGMENT_LAYOUT_NO_COLUMNS)
    # 이웃 조각의 왼쪽 끝 간격은 (1 - 폭) / (조각 수 - 1)이라, 겹치는 폭은 조각 폭에서 그 간격을 뺀 것이다.
    ratio = COLUMN_SPLIT_WIDTH_RATIO
    overlap = _overlap_phrase(ratio - (1 - ratio) / (COLUMN_SPLIT_COUNT - 1))
    particle = "는" if overlap.endswith("%") else _TOPIC_PARTICLE_BY_LAST_DIGIT[overlap[-1]]
    template = FRAGMENT_LAYOUT_TWO_COLUMNS if COLUMN_SPLIT_COUNT == 2 else FRAGMENT_LAYOUT_MANY_COLUMNS
    layout = template.format(count=COLUMN_SPLIT_COUNT, overlap=overlap, overlap_topic=overlap + particle)
    return FRAGMENT_NOTE.format(fragment_layout=layout)


def _call_model(
    client: OpenAI,
    tile_group: list[Image.Image],
    max_tokens: int,
    batch_label: str = "",
) -> dict:
    """타일 여러 개(한 배치)를 한 요청으로 모델에 보내고 POSTER_INFO_SCHEMA dict를 반환한다.
    system 프롬프트에는 항상 FRAGMENT_NOTE를 덧붙여, 지금 보는 이미지가 전체 페이지의 일부
    구간일 뿐이라는 것과 안 보이는 정보는 null로 두라는 것을 모델에 알린다."""
    system_prompt = POSTER_SYSTEM_PROMPT + _fragment_note()

    response = client.chat.completions.create(
        model=MODEL_NAME,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": _batch_user_content(tile_group)},
        ],
        temperature=0,
        max_tokens=max_tokens,
        response_format=_POSTER_INFO_RESPONSE_FORMAT,
    )

    choice = response.choices[0]
    if choice.finish_reason == "length":
        raise _TruncatedResponseError(
            f"{batch_label}응답이 max_tokens({max_tokens}) 한도에 걸려 중간에 잘렸습니다 "
            "(그 구간에 라인업/타임테이블 항목이 너무 많을 수 있음)."
        )

    return json.loads(choice.message.content)


class _TruncatedResponseError(RuntimeError):
    """finish_reason == "length"로 응답이 잘렸을 때만 던지는 전용 예외. 다른 RuntimeError와
    구분해서 _call_batch_with_split_retry가 "잘렸을 때만" 배치를 쪼개 재시도하게 한다(문자열
    매칭 대신 타입으로 구분 - _classify_error의 메시지 매칭보다 안전하다)."""


def _call_batch_with_split_retry(
    client: OpenAI,
    tile_group: list[Image.Image],
    max_tokens: int,
    batch_label: str,
) -> list[dict]:
    """배치 하나를 호출하고, 응답이 max_tokens에 걸려 잘리면(_TruncatedResponseError) 그 배치를
    타일 절반씩 나눠 각각 재귀적으로 다시 시도한다(2026-09-02 추가).

    예전엔 배치 하나가 잘리면 그 즉시 예외가 extract_poster_info 밖으로 전파돼 이미지 전체
    추출이 실패했다 - 이미 성공한 다른 배치 결과까지 통째로 버려지고, 실패 유형은 계속
    "truncated_response"로 반복 관측됐다(failed.jsonl 실측). 원래 타일들이 이미 겹치는 구간을
    두고 잘려 있으므로(split_into_tiles의 TILE_OVERLAP_PX), 배치를 반으로 쪼개도 내용 손실은
    없고 "한 응답에 나열해야 할 항목 수"만 줄어든다 - 그만큼 잘릴 확률이 낮아진다. 각 하위
    배치는 독립된 POSTER_INFO_SCHEMA dict를 내므로, 호출부는 그냥 리스트를 이어붙여
    _merge_results에 넘기면 된다(이미 여러 배치 결과를 병합하는 경로라 자연스럽게 들어맞음).

    타일 1장짜리까지 쪼갰는데도 잘리면 더 쪼갤 수 없다. 2026-09-14부터는 이때 예외를 전파하지 않고
    그 타일 결과만 비운다(stderr 경고). 실측상 이 경우는 항목이 많아서가 아니라 모델이 같은 이름을
    반복하는 루프에 빠진 것이라 재시도해도 소용없고, 예외를 올리면 다른 배치의 정상 결과까지 전부
    버려진다. 타일끼리 겹치는 구간이 있어 한 타일을 버려도 손실이 작다."""
    try:
        return [_call_model(client, tile_group, max_tokens, batch_label)]
    except _TruncatedResponseError as exc:
        if len(tile_group) <= 1:
            print(f"[경고] {exc} - 이 타일 결과는 건너뜁니다.", file=sys.stderr)
            return []
        mid = len(tile_group) // 2
        left, right = tile_group[:mid], tile_group[mid:]
        return _call_batch_with_split_retry(
            client, left, max_tokens, f"{batch_label}(전반 재시도) "
        ) + _call_batch_with_split_retry(
            client, right, max_tokens, f"{batch_label}(후반 재시도) "
        )


def _call_timetable_model(client: OpenAI, piece: Image.Image, label: str) -> dict | None:
    """시간표 구간 조각 1장을 TIMETABLE_SYSTEM_PROMPT로 보내고, _timetable_region_result로 정리한 결과를
    돌려준다(extract_from_timetable.py의 extract_timetable_info에서 옮김 - FRAGMENT_NOTE는 붙이지 않는다).
    응답이 max_tokens에 걸려 잘리면 타일 1장이 잘렸을 때처럼 경고만 남기고 None을 돌려준다 - 더 쪼갤 수
    없고 예외를 올리면 다른 배치의 정상 결과까지 버려진다. max_tokens는 배치와 같은 BATCH_MAX_TOKENS를
    써서 REQUEST_TIMEOUT_SEC 계산이 그대로 맞게 한다(예전 extract_from_timetable.py는 32768)."""
    response = client.chat.completions.create(
        model=MODEL_NAME,
        messages=[
            {"role": "system", "content": TIMETABLE_SYSTEM_PROMPT},
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": TIMETABLE_USER_PROMPT},
                    {"type": "image_url", "image_url": {"url": image_to_data_uri(piece)}},
                ],
            },
        ],
        temperature=0,
        max_tokens=BATCH_MAX_TOKENS,
        response_format=_POSTER_INFO_RESPONSE_FORMAT,
    )

    choice = response.choices[0]
    if choice.finish_reason == "length":
        print(
            f"[경고] {label}응답이 max_tokens({BATCH_MAX_TOKENS}) 한도에 걸려 중간에 잘렸습니다 - "
            "이 조각 결과는 건너뜁니다.",
            file=sys.stderr,
        )
        return None
    return _timetable_region_result(json.loads(choice.message.content))


def _timetable_region_calls(client: OpenAI, im: Image.Image, timetable_ranges: list[tuple[int, int]]) -> list:
    """시간표 구간마다 split_timetable_region으로 자른 조각을 _call_timetable_model 호출로 만든다."""
    calls = []
    for top, bottom in timetable_ranges:
        pieces = split_timetable_region(im, top, bottom)
        for j, piece in enumerate(pieces):
            label = f"[시간표 구간 y={top}-{bottom} {j + 1}/{len(pieces)}] "
            calls.append(partial(_call_timetable_model, client, piece, label))
    return calls


def _run_parallel(calls: list) -> list:
    """인자 없는 호출들을 스레드풀로 동시에 보내고, 넣은 순서대로 결과를 돌려준다."""
    if not calls:
        return []
    with ThreadPoolExecutor(max_workers=min(BATCH_CONCURRENCY, len(calls))) as pool:
        futures = [pool.submit(call) for call in calls]
        return [f.result() for f in futures]


def extract_poster_info(
    image: str,
    base_url: str,
    api_key: str = "EMPTY",
    timeout: float = REQUEST_TIMEOUT_SEC,
    timetable_ranges: list[tuple[int, int]] | None = None,
) -> dict:
    """상세페이지 이미지 1장에서 백엔드 계약 6키 결과를 뽑는다. timetable_ranges는 원본 이미지 안 시간표
    구간의 세로 픽셀 범위 [(top, bottom), ...]다 - 주면 그 구간을 시간표 방식으로 따로 읽어 아티스트
    시간표를 그 결과로 대체하고, 안 주면(None 또는 []) 페스티벌의 아티스트 시간표는 비운다(_merge_results)."""
    client = OpenAI(base_url=base_url, api_key=api_key, timeout=timeout)

    im = load_image(image)
    tiles = split_into_tiles(im)

    # 2026-09-13: 타일이 1장뿐인 일반 포스터용 단일 요청 경로를 없앴다 - 타일 수와 상관없이
    # 항상 아래 분할 경로(FRAGMENT_NOTE 포함)로 보낸다.
    # 타일을 이미지 토큰 예산 안에서 여러 배치로 나누고, 배치들을
    # 스레드풀로 "동시에" 요청한다(2026-09-02 변경). 예전엔 순차(list comprehension)로 하나씩
    # 기다렸는데, 배치가 N개면 최악의 경우 대기 시간이 N x REQUEST_TIMEOUT_SEC까지 쌓여 - 라인업이
    # 많아 배치 수가 많아지는 대형 페스티벌 이미지일수록(가장 놓치면 안 되는 이미지일수록)
    # 타임아웃에 더 잘 걸리는 역설이 있었다. vLLM은 continuous batching으로 여러 요청을 동시에
    # 받아도 처리 가능하므로(test_batch_extract.py가 이미지 "간" 동시 처리에 쓰는 것과 같은 근거),
    # 배치 순서대로 결과를 모아도(pool.submit 후 원래 순서로 .result() 호출) 총 대기 시간은
    # "가장 오래 걸린 배치 1개" 수준으로 줄어든다. ticketing_date의 "먼저 나온 값 우선" 동표
    # 처리(_pick_ticketing_date)가 배치 제출 순서에 의존하므로, results 리스트 순서는 그대로
    # 유지한다(동시 실행 자체는 순서에 영향 없음 - future를 만든 순서대로 결과를 받을 뿐).
    # 각 배치는 _call_batch_with_split_retry를 거치므로, 응답이 max_tokens에 걸려 잘려도 그
    # 배치 하나만 내부적으로 더 잘게 쪼개져 재시도되고(위 함수 설명 참고), 성공하면 dict 1개가
    # 아니라 여러 개로 늘어날 수 있다 - 그래서 future.result()가 list[dict]를 반환하고, 여기서
    # 평탄화(flatten)해서 하나의 results 리스트로 만든다.
    # 2026-09-25: 시간표 구간 조각은 타일 결과와 무관하게 읽으므로 같은 스레드풀에 함께 넣는다.
    batches = group_into_batches(tiles)
    batch_calls = [
        partial(_call_batch_with_split_retry, client, batch, BATCH_MAX_TOKENS, f"[배치 {i + 1}/{len(batches)}] ")
        for i, batch in enumerate(batches)
    ]
    region_calls = _timetable_region_calls(client, im, timetable_ranges or [])
    outputs = _run_parallel(batch_calls + region_calls)

    results = [r for rs in outputs[: len(batch_calls)] for r in rs]
    timetable_results = [r for r in outputs[len(batch_calls):] if r is not None] if timetable_ranges else None
    return _merge_results(results, timetable_results)


def extract_timetable_info(
    image: str,
    base_url: str,
    api_key: str = "EMPTY",
    timeout: float = REQUEST_TIMEOUT_SEC,
) -> dict:
    """손으로 자른 시간표 이미지 1장에서 6키 결과를 뽑는다(--timetable-crop, 예전 extract_from_timetable.py).
    이미지 전체를 시간표 구간 하나로 보고 extract_poster_info의 구간 경로와 똑같이 읽는다 - 타일 배치가
    없으므로 티켓/배송/가격/음식물 필드는 항상 null이다."""
    client = OpenAI(base_url=base_url, api_key=api_key, timeout=timeout)

    im = load_image(image)
    outputs = _run_parallel(_timetable_region_calls(client, im, [(0, im.height)]))
    return _merge_results([], [r for r in outputs if r is not None])


def _classify_error(exc: BaseException) -> str:
    """실패 유형을 짧은 문자열로 분류한다 - failed.jsonl에 남겨 나중에 "몇 건이 진짜 타임아웃
    때문에 죽었는지" 같은 원인별 집계를 바로 할 수 있게 한다. 특히 타임아웃과 그 외 에러를
    구분하는 게 중요하다(REQUEST_TIMEOUT_SEC을 더 올려야 하는지 판단하는 근거가 되므로)."""
    if isinstance(exc, (openai.APITimeoutError, TimeoutError)):
        return "timeout"
    if isinstance(exc, openai.APIConnectionError):
        return "connection_error"
    if isinstance(exc, _TruncatedResponseError):
        # _call_batch_with_split_retry가 이미 배치를 타일 1장까지 쪼개 재시도해봤는데도 잘린
        # 경우만 여기까지 올라온다 - 타일 1장 자체가 max_tokens를 넘게 촘촘하다는 뜻이므로
        # BATCH_MAX_TOKENS를 더 올리거나 MAX_PIXELS_PER_TILE을 낮춰야 할 수 있다.
        return "truncated_response"
    if isinstance(exc, openai.APIStatusError):
        return "api_status_error"
    if isinstance(exc, requests.exceptions.RequestException):
        return "image_download_error"
    if isinstance(exc, (json.JSONDecodeError, KeyError, ValueError)):
        return "response_parse_error"
    return "other"


def _append_failure_log(out_dir: Path, image: str, error_type: str, exc: BaseException, elapsed: float) -> None:
    """실패 건을 <out_dir>/failed.jsonl에 한 줄씩 이어붙인다(append). 터미널 로그가 스크롤로
    사라져도 이 파일만 보면 어떤 이미지가 왜(타임아웃/기타) 실패했는지 다시 확인할 수 있고,
    error_type별로 집계해 재발 여부를 추적할 수 있다."""
    record = {
        "image": image,
        "error_type": error_type,
        "error_message": str(exc),
        "elapsed_sec": round(elapsed, 1),
        "failed_at": datetime.now(timezone.utc).isoformat(),
        "pipeline_version": PIPELINE_VERSION,
    }
    with (out_dir / "failed.jsonl").open("a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


def _is_up_to_date(out_path: Path) -> bool:
    """out_path에 이미 "현재 PIPELINE_VERSION"으로 만들어진 결과가 있으면 True. 버전 표시가 없는
    (PIPELINE_VERSION 도입 이전) 구버전 파일이나 손상된 JSON은 최신이 아닌 것으로 보고 재처리
    대상에 남긴다."""
    if not out_path.exists():
        return False
    try:
        data = json.loads(out_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return False
    return data.get("_pipeline_version") == PIPELINE_VERSION


def _parse_range(text: str) -> tuple[int, int]:
    """--timetable-range 값 "TOP:BOTTOM"을 (top, bottom) 정수 쌍으로 바꾼다."""
    try:
        top, bottom = (int(v) for v in text.split(":"))
    except ValueError:
        raise argparse.ArgumentTypeError(f"TOP:BOTTOM 형식의 정수 두 개여야 합니다: {text!r}") from None
    if bottom <= top:
        raise argparse.ArgumentTypeError(f"BOTTOM이 TOP보다 커야 합니다: {text!r}")
    return top, bottom


def main():
    parser = argparse.ArgumentParser(description="공연 소개 이미지에서 정형 정보 추출")
    parser.add_argument("images", nargs="+", help="공연 소개 이미지 URL 또는 로컬 파일 경로 (여러 개 가능)")
    timetable_group = parser.add_mutually_exclusive_group()
    timetable_group.add_argument(
        "--timetable-range",
        type=_parse_range,
        action="append",
        metavar="TOP:BOTTOM",
        help=(
            "시간표 구간의 세로 픽셀 범위(원본 이미지 기준). 여러 구간이면 옵션을 반복한다. 주면 그 구간을 "
            "시간표 방식으로 읽어 아티스트 시간표를 대체하고, 안 주면 페스티벌의 아티스트 시간표는 비운다. "
            "모든 이미지에 같은 범위가 쓰이므로 보통 이미지 1장과 함께 쓴다."
        ),
    )
    timetable_group.add_argument(
        "--timetable-crop",
        action="store_true",
        help="이미지들이 시간표만 잘라둔 이미지면 지정한다(이미지 전체를 시간표 구간 하나로 읽음, 예전 extract_from_timetable.py).",
    )
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
    parser.add_argument(
        "--skip-up-to-date",
        action="store_true",
        help=(
            "--out-dir에 이미 현재 파이프라인 버전(PIPELINE_VERSION)으로 만들어진 결과가 있는 "
            "이미지는 재처리를 건너뛴다. 버전 표시가 없는 구버전 결과나 --resume처럼 '파일 존재 "
            "여부'만으로 건너뛰지 않으므로, 예전 실패/구버전 결과가 계속 방치되지 않는다."
        ),
    )
    args = parser.parse_args()

    out_dir = Path(args.out_dir) if args.out_dir else None
    if out_dir:
        out_dir.mkdir(parents=True, exist_ok=True)

    exit_code = 0
    for image in args.images:
        label = Path(image).name if not image.startswith("http") else image
        out_path = out_dir / f"{Path(image).stem}.json" if out_dir else None

        if args.skip_up_to_date and out_path is not None and _is_up_to_date(out_path):
            print(f"[{label}] 이미 최신 버전({PIPELINE_VERSION}) 결과 있음, 건너뜀")
            continue

        start = time.monotonic()
        try:
            if args.timetable_crop:
                result = extract_timetable_info(image, args.base_url, args.api_key, timeout=args.timeout)
            else:
                result = extract_poster_info(
                    image, args.base_url, args.api_key, timeout=args.timeout, timetable_ranges=args.timetable_range
                )
        except Exception as exc:  # noqa: BLE001
            elapsed = time.monotonic() - start
            error_type = _classify_error(exc)
            print(f"[{label}] 추출 실패 [{error_type}] ({elapsed:.1f}초): {exc}", file=sys.stderr)
            if out_dir:
                _append_failure_log(out_dir, image, error_type, exc, elapsed)
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

        if out_path is not None:
            out_path.write_text(text, encoding="utf-8")

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
