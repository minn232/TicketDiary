"""
공연 포스터에서 '출연 아티스트명'만 뽑는 전용 로직. extract_poster.py(타임테이블/가격/배송일/
음식물 반입 여부까지 뽑는 범용 poster_info)와 프롬프트/스키마를 분리함.
크롤링 스크린샷 분석(analyze_crawl_screenshot)은 그대로 extract_poster.py 사용 - 
KOPIS로 이미 채워진 공연은 이 함수 자체가 호출 안 됨(프롬프트로 손댈 범위 아님).

사전 준비: extract_poster.py와 같은 vLLM 서버(모델 하나만 뜸)를 공유해서 쓴다.
    vllm serve Qwen/Qwen2.5-VL-7B-Instruct-AWQ \
        --quantization awq \
        --max-model-len 65536 \
        --mm-processor-kwargs '{"max_pixels": 1500000, "min_pixels": 3136}' \
        --limit-mm-per-prompt '{"image": 32}'

사용:
    # URL
    python extract_artist.py "https://example.com/poster.jpg" --concert-name "9와 숫자들: 99%, Best"

    # 로컬 파일 (여러 장 가능, glob도 지원) - concert_name 생략 가능
    python extract_artist.py /workspace/poster_image/*.png --out-dir /workspace/artist_extractor/results
"""

import argparse
import base64
import io
import json
import sys
from pathlib import Path

import requests
from openai import OpenAI
from PIL import Image

from schema import LINEUP_ENTRY_SCHEMA

MODEL_NAME = "Qwen/Qwen2.5-VL-7B-Instruct-AWQ"

# 타일링 상수는 extract_poster.py와 동일(같은 포스터 이미지를 다룸) - 바꾸면 그쪽도 맞출 것
MAX_PIXELS_PER_TILE = 1_500_000
TILE_OVERLAP_PX = 100
MAX_TILES = 18
TALL_IMAGE_RATIO = 1.6

USER_PROMPT = "이 공연 포스터에서 위 규칙에 따라 출연 아티스트명을 추출해줘."


def _build_system_prompt(concert_name: str | None) -> str:
    concert_line = f'이 공연의 제목은 "{concert_name}"입니다.\n\n' if concert_name else ""
    return f"""\
당신은 공연 포스터에서 출연 아티스트명만 정확히 추출하는 어시스턴트입니다.
{concert_line}핵심 원칙 (반드시 순서대로 따르세요):
1. 아티스트명은 반드시 이미지 안에 실제로 인쇄되거나 표시된 텍스트에서만 가져오세요.
   인물의 얼굴, 스타일, 분위기를 보고 당신이 이미 알고 있는 실제 이름(본명 등)이나
   배경지식으로 답하지 마세요 - 그 이름이 이미지 안에 글자로 쓰여 있지 않다면 절대 쓰지
   말고 null로 두세요. (예: 포스터에 활동명만 쓰여 있으면 활동명만 답하고, 이미지에 없는
   본명으로 바꿔 쓰지 마세요.)
2. 공연장/시설명(예: "OO홀", "OO체육관", "OO아트센터", "OO돔" 등)은 아티스트명이
   아닙니다. 장소 이름을 아티스트명으로 착각해 넣지 마세요.
3. 이미지 안에 크기/스타일이 다른 여러 문구가 함께 있을 때, 가장 크거나 장식적인 문구가
   항상 아티스트명은 아닙니다. "~단독공연", "~콘서트", "~라이브", "~투어" 같은 문구
   바로 앞이나 뒤에 오는 이름을 아티스트명 후보로 우선하고, 그 옆에 있는 부제/앨범명/
   투어명/EP명과 혼동하지 마세요.
4. 위에 주어진 공연 제목은 처음부터 적극적으로 참고하세요(이미지에서 못 찾았을 때만
   보는 최후 수단이 아닙니다). 제목은 흔히 "아티스트명: 부제" 또는 "아티스트명 콘서트:
   부제" 형식이라 제목 안에 아티스트명이 그대로 들어있는 경우가 많습니다(예: "9와
   숫자들: 99%, Best"). 이미지 안에 여러 후보 문구가 있어 어느 게 아티스트명인지
   헷갈릴 때는 제목과 일치하거나 제목에 포함된 후보를 우선하세요. 단, 제목 맨 앞이
   방송사/주최사/공연 시리즈나 페스티벌 브랜드명("OO대기획", "OO상상마당", "OO
   LIVE SERIES", "OO페스타", "마티네 콘서트" 등)이고 실제 공연자명은 쉼표 뒤나
   뒷부분에 따로 있는 경우도 흔하니, 제목 맨 앞 글자만 기계적으로 자르지 말고 어느
   부분이 실제 "사람/팀 이름"인지 판단하세요. 이미지에서 아티스트명을 전혀 특정할 수
   없을 때는 이 판단을 그대로 최종 답으로 써도 됩니다(추측이 아니라 미리 제공된
   정보를 쓰는 것). 다만 이미지에 뚜렷이 다른 이름이 적혀 있어 명백히 모순되면
   이미지 쪽을 따르세요.
5. 위 방법으로도 특정할 수 없는 정보는 추측하지 말고 null로 두세요.

라인업 작성 방법:
- 출연하는 가수/팀마다 한 항목씩, artist(가수명)와 performance_date(출연 날짜, YYYY-MM-DD,
  모르면 null)로 구성된 배열을 만드세요.
- 라인업이 전혀 공개되지 않은 블라인드 상태면 항목 1개만 만들고 artist=null,
  performance_date=null로 둡니다.
- 같은 출연진이 한글명과 영문명(또는 그 외 서로 다른 표기)으로 각각 표시돼 있다고 해서
  서로 다른 두 팀으로 착각해 항목을 두 개 만들지 마세요. 최종 목록을 만들기 전에 지금까지
  나온 이름들을 서로 비교해 같은 인물/팀을 가리키는 표기가 없는지 확인하세요. 동일
  인물/팀으로 판단되면 항목 하나로 합치고, artist에는 이미지에 실제로 나온 두 표기를
  그대로 이어 붙여 씁니다.
- 이미지에 한자/가나/키릴 문자 등 한글도 로마자도 아닌 외국어 표기만 있고, 위에 주어진
  공연 제목에 같은 대상을 가리키는 로마자 표기가 있다면(예: 이미지엔 "名誉×伝説"만,
  제목엔 "MEIYO DENSETSU"), 이미지 표기 대신 **제목의 로마자 표기를 최종 답으로** 쓰세요
  (즉 "名誉×伝説"이 아니라 "MEIYO DENSETSU"). 바로 위 규칙(한글명+로마자명 병기)과 달리
  이 경우는 병기하지 않고 로마자 하나로 통일합니다 - 외국어 원어 표기보다 로마자 표기가
  검색/매칭에 더 일관적이기 때문입니다. 제목에 대응하는 로마자 표기가 없으면(원어 표기만
  있고 로마자로 뭐라 하는지 알 수 있는 정보가 없으면) 억지로 로마자로 바꾸지 말고 이미지에
  실제로 적힌 원어 표기를 그대로 쓰세요 - 모르는 로마자 표기를 지어내지 마세요.

반드시 주어진 JSON 스키마 형식으로만 답하세요.
"""


ARTIST_LINEUP_SCHEMA = {
    "type": "object",
    "properties": {
        "lineup": {
            "type": "array",
            "items": LINEUP_ENTRY_SCHEMA,
        },
    },
    "required": ["lineup"],
    "additionalProperties": False,
}


def load_image(image: str) -> Image.Image:
    if image.startswith("http://") or image.startswith("https://"):
        resp = requests.get(image, timeout=30)
        resp.raise_for_status()
        return Image.open(io.BytesIO(resp.content)).convert("RGB")
    return Image.open(image).convert("RGB")


def split_into_tiles(im: Image.Image) -> list[Image.Image]:
    """세로로 매우 긴 이미지를 겹치는 구간을 둔 여러 조각으로 자른다. extract_poster.py와
    동일 로직(중복이지만, 이 파일을 독립적으로 유지·동기화하기 위해 그대로 복사)."""
    w, h = im.size
    if h / w < TALL_IMAGE_RATIO and w * h <= MAX_PIXELS_PER_TILE:
        return [im]

    tile_h = max(200, MAX_PIXELS_PER_TILE // w)
    step = max(1, tile_h - TILE_OVERLAP_PX)

    if -(-h // step) > MAX_TILES:  # 타일 수가 너무 많아지면 타일을 키워서 개수를 제한
        tile_h = -(-h // MAX_TILES) + TILE_OVERLAP_PX
        step = max(1, tile_h - TILE_OVERLAP_PX)

    tiles = []
    top = 0
    while top < h:
        bottom = min(h, top + tile_h)
        tiles.append(im.crop((0, top, w, bottom)))
        if bottom >= h:
            break
        top += step
    return tiles


def image_to_data_uri(im: Image.Image) -> str:
    buf = io.BytesIO()
    im.save(buf, format="PNG")
    data = base64.b64encode(buf.getvalue()).decode("utf-8")
    return f"data:image/png;base64,{data}"


def extract_artist_info(image: str, concert_name: str | None, base_url: str, api_key: str = "EMPTY") -> dict:
    client = OpenAI(base_url=base_url, api_key=api_key)

    im = load_image(image)
    tiles = split_into_tiles(im)

    content = [{"type": "text", "text": USER_PROMPT}]
    if len(tiles) > 1:
        content.append({
            "type": "text",
            "text": (
                f"아래 {len(tiles)}장의 이미지는 세로로 긴 하나의 상세페이지를 "
                "위에서 아래 순서대로 자른 조각들이다(경계 부근은 겹칠 수 있음). "
                "전체를 하나의 이미지로 간주하고 정보를 종합해서 답해라."
            ),
        })
    for tile in tiles:
        content.append({"type": "image_url", "image_url": {"url": image_to_data_uri(tile)}})

    response = client.chat.completions.create(
        model=MODEL_NAME,
        messages=[
            {"role": "system", "content": _build_system_prompt(concert_name)},
            {"role": "user", "content": content},
        ],
        temperature=0,
        max_tokens=2048,
        response_format={
            "type": "json_schema",
            "json_schema": {
                "name": "artist_info",
                "schema": ARTIST_LINEUP_SCHEMA,
                "strict": True,
            },
        },
    )

    raw = response.choices[0].message.content
    return json.loads(raw)


def main():
    parser = argparse.ArgumentParser(description="공연 포스터에서 출연 아티스트명 추출")
    parser.add_argument("images", nargs="+", help="공연 포스터 이미지 URL 또는 로컬 파일 경로 (여러 개 가능)")
    parser.add_argument("--concert-name", default=None, help="공연 제목 (원칙 4번에서 힌트로 참고됨, 생략 가능)")
    parser.add_argument(
        "--base-url",
        default="http://localhost:8000/v1",
        help="vLLM OpenAI 호환 서버 주소 (기본값: http://localhost:8000/v1)",
    )
    parser.add_argument("--api-key", default="EMPTY", help="vLLM은 보통 임의 문자열이면 충분")
    parser.add_argument("--out-dir", default=None, help="지정하면 이미지별 결과를 <파일명>.json으로 저장")
    args = parser.parse_args()

    out_dir = Path(args.out_dir) if args.out_dir else None
    if out_dir:
        out_dir.mkdir(parents=True, exist_ok=True)

    exit_code = 0
    for image in args.images:
        label = Path(image).name if not image.startswith("http") else image
        try:
            result = extract_artist_info(image, args.concert_name, args.base_url, args.api_key)
        except Exception as exc:  # noqa: BLE001
            print(f"[{label}] 추출 실패: {exc}", file=sys.stderr)
            exit_code = 1
            continue

        text = json.dumps(result, ensure_ascii=False, indent=2)
        if len(args.images) > 1:
            print(f"=== {label} ===")
        print(text)

        if out_dir:
            out_path = out_dir / f"{Path(image).stem}.json"
            out_path.write_text(text, encoding="utf-8")

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
