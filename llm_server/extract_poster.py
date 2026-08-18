"""
공연 소개 이미지(URL 또는 로컬 파일)를 Qwen2.5-VL-7B-Instruct-AWQ(vLLM 서버)에 전달해
타임테이블 / 라인업 / 티켓팅 오픈일 / 티켓 배송일 / 가격 / 음식물 반입 여부를 JSON으로 추출한다.

티켓 상세페이지 캡처 이미지는 세로로 매우 길다(예: 1920x16238). 통째로 모델에 넣으면
비전 인코더가 거대한 단일 이미지를 처리하며 GPU 메모리가 터지거나(OOM), 강제로
축소되면서 하단부 글자가 뭉개진다. 이를 막기 위해 세로로 김/큰 이미지는 겹치는
구간을 두고 여러 조각으로 잘라 한 메시지에 순서대로 넣는다.

사전 준비:
    vllm serve Qwen/Qwen2.5-VL-7B-Instruct-AWQ \
        --quantization awq \
        --max-model-len 65536 \
        --mm-processor-kwargs '{"max_pixels": 1500000, "min_pixels": 3136}' \
        --limit-mm-per-prompt '{"image": 32}'

사용:
    # URL
    python extract_poster.py "https://example.com/poster.jpg"

    # 로컬 파일 (여러 장 가능, glob도 지원)
    python extract_poster.py /workspace/poster_image/*.png --out-dir /workspace/poster_extractor/results
    python server/extract_poster.py poster_image/20260713_184727_장기하_X_카더가든__MINTPAPER_20th_SPE_kopis.png

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

from schema import POSTER_INFO_SCHEMA

MODEL_NAME = "Qwen/Qwen2.5-VL-7B-Instruct-AWQ"

# 타일 하나가 감당할 최대 픽셀 수. 서버의 --mm-processor-kwargs max_pixels 와 맞춰둔다.
MAX_PIXELS_PER_TILE = 1_500_000
TILE_OVERLAP_PX = 100
# 타일(이미지) 수가 너무 많으면 모델이 같은 이름을 계속 반복 생성하는 루프에 빠지는
# 경향이 있어 상한을 낮게 잡는다. 대신 타일 개수가 이 값을 넘으면 타일을 더 키운다.
MAX_TILES = 18
# 세로/가로 비율이 이보다 크면 "상세페이지 캡처형" 이미지로 보고 타일링한다.
TALL_IMAGE_RATIO = 1.6

SYSTEM_PROMPT = """\
당신은 공연/페스티벌 홍보 이미지를 분석해 정형 데이터를 추출하는 어시스턴트입니다.
이미지에 보이는 텍스트와 표를 근거로만 답하고, 이미지에 없는 정보는 null 또는 빈 배열로 두세요. 추측하지 마세요.
연도가 이미지에 없으면 이미지에 함께 적힌 공연 날짜의 연도를 사용합니다.
어떤 필드든 이미지 내용만으로 정확히 판단할 수 없으면 절대로 추측하거나 지어내지 말고 반드시 null(배열 필드는 null 또는 빈 배열)로 두세요.

1. timetable (타임테이블): 출연하는 가수/팀마다 한 항목씩, performance_date(출연 날짜, YYYY-MM-DD), time(공연 시각, HH:MM), artist(가수명), stage(무대명)로 구성된 배열입니다.
   아래 세 가지 경우를 구분해서 채우세요.
   - 라인업이 전혀 공개되지 않은 블라인드 상태: 항목 1개만 만들고 artist=null, performance_date=null, time=null, stage=null 로 채웁니다.
   - 라인업(출연 가수명)은 공개됐지만 날짜/시간/무대 등 타임테이블 자체는 공개되지 않은 경우:
     공개된 가수마다 항목을 만들되 artist는 실제 이름을 쓰고 performance_date, time, stage는 모두 null로 둡니다.
   - 날짜/시간/무대가 실제로 이미지에 적혀 있는 경우: 공개된 값을 그대로 채웁니다(일부만 적혀 있으면 그 항목만 채우고 나머지는 null). 단독 공연이라도 동일하게 한 항목으로 채웁니다.
   - 이미지에서 출연진 정보를 전혀 특정할 수 없는 경우(블라인드 표시조차 없음)에만 timetable 전체를 null로 둡니다.
   - 타임테이블 표기 형식: 이미지 속 타임테이블은 가로 또는 세로 축을 따라 시각 눈금(예: 12:00, 13:00, 14:00 ...)이 표시되어 있고, 그 축 위에 배치된 막대(바)나 구간 안(또는 바로 옆)에 아티스트명과 공연시간이 함께 적혀 있는 그래프/차트 형식입니다. 막대의 위치나 길이만으로 시각을 추측하지 말고, 막대 안/근처에 실제로 적힌 아티스트명과 시각 텍스트를 근거로 판단하세요. 시각이 텍스트로 명시되어 있지 않다면 축 눈금과 막대의 시작/끝 위치를 비교해 가장 가까운 눈금값을 시각으로 사용하세요.
   - 중복 방지: 같은 출연진이 한글명과 영문명(또는 그 외 서로 다른 표기)으로 각각 표시돼 있다고 해서 서로 다른 두 팀으로 착각해 항목을 두 개 만들지 마세요. 특히 출연진 소개 구간(사진과 함께 나오는 이름)과 타임테이블 구간의 표기가 서로 다른 언어/스타일로 적혀 같은 이미지 안에 따로 등장하는 경우가 흔합니다.
     최종 목록을 만들기 전에 지금까지 나온 이름들을 서로 비교해 같은 인물/팀을 가리키는 표기가 없는지 반드시 확인하세요. 동일 인물/팀으로 판단되면 항목 하나로 합치고, artist에는 이미지에 실제로 나온 두 표기를 그대로 이어 붙여 씁니다. 이미지에서 실제로 읽은 표기가 아닌 이름은 절대 쓰지 마세요. 날짜나 시간이 서로 달라 실제로 별개의 출연 회차인 것이 확실할 때만 별도 항목으로 유지하세요.
2. lineup (라인업): timetable과 동일한 가수 목록을, artist(가수명)와 performance_date(그 가수의 출연 날짜, 모르면 null)로 구성된 배열로 나열합니다. 블라인드 상태면 artist=null, performance_date=null 로 둡니다. timetable과 동일하게 한글명/영문명
   등 표기만 다른 동일 출연진을 중복 항목으로 나누지 말고 하나로 합쳐 적습니다.
3. ticketing_date (티켓팅/예매 오픈일): "예매오픈", "티켓오픈", "판매시작", "OO예매" 등으로
   표시된 티켓 구매 시작 날짜를 YYYY-MM-DD로 변환합니다. 시간(HH:MM)까지 적혀 있어도 날짜만
   씁니다. 선예매/1차/2차/일반예매처럼 단계가 여러 개면 그중 **가장 이른 날짜**를 씁니다(유저가
   놓치면 안 되는 첫 기회이기 때문). 예매 오픈 관련 언급이 전혀 없으면 null로 둡니다. 공연
   당일/회차 날짜(timetable)나 배송일(ticket_delivery_date)과 혼동하지 마세요 - 이건 "티켓을
   살 수 있게 되는 날"입니다.
4. ticket_delivery_date (티켓 배송 날짜): 이미지에 명시된 날짜가 있으면 YYYY-MM-DD로 변환합니다. 배송 관련 언급이 전혀 없으면 null로 둡니다.
5. ticket_prices (이용권/좌석별 가격): 매우 보수적으로 채우세요. 이미지 안 한 곳에 "구분 명칭"과 "정확한 금액(원)"이 서로 붙어 나란히 인쇄되어 있는 것을 실제로 두 눈으로 읽었을 때만 항목을 만들고, 그 글자와 숫자를 있는 그대로 seat_type과 price(정수, 원 단위)로 옮겨 적으세요.
   - 지정석 공연인 경우: 좌석 등급/구역별 가격을 seat_type/price로 작성합니다. 좌석별 가격이 이미지에 나와있지 않으면 ticket_prices=null입니다.
   - 비지정석 공연인 경우: 관람 일수 기준 이용권 종류(예: 단일권, 양일권 등)별 가격을 seat_type/price로 작성합니다. 가격이 이미지에 나와있지 않으면 ticket_prices=null입니다.
6. other_info.food_allowed (음식물 반입 가능 여부): "반입 가능 물품"/"반입 금지 물품" 아이콘 안내가 있는지 먼저 확인하세요(예: "500ml 이하 페트병/텀블러 음료는 가능, 병/캔/유리 용기·500ml 초과 음료·도시락 등은 금지" 처럼 아이콘과 짧은 설명으로 표시되는 경우가 많습니다).
   - 모든 외부 음식/음료가 금지면 "불가능".
   - 생수·작은 텀블러·간단한 간식 등 일부 품목만 허용하고 나머지(도시락, 배달음식, 일정 용량 초과 음료 등)는 금지면 "일부허용".
   - 제한 없이 자유롭게 반입 가능하면 "가능".
   - 언급이 전혀 없으면 null로 둡니다.

반드시 주어진 JSON 스키마 형식으로만 답하세요.
"""

USER_PROMPT = "이 공연 소개 이미지에서 위 규칙에 따라 정보를 추출해줘."


def load_image(image: str) -> Image.Image:
    if image.startswith("http://") or image.startswith("https://"):
        resp = requests.get(image, timeout=30)
        resp.raise_for_status()
        return Image.open(io.BytesIO(resp.content)).convert("RGB")
    return Image.open(image).convert("RGB")


def split_into_tiles(im: Image.Image) -> list[Image.Image]:
    """세로로 매우 긴 이미지를 겹치는 구간을 둔 여러 조각으로 자른다."""
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


def extract_poster_info(image: str, base_url: str, api_key: str = "EMPTY") -> dict:
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
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": content},
        ],
        temperature=0,
        max_tokens=8192,
        response_format={
            "type": "json_schema",
            "json_schema": {
                "name": "poster_info",
                "schema": POSTER_INFO_SCHEMA,
                "strict": True,
            },
        },
    )

    raw = response.choices[0].message.content
    return json.loads(raw)


def main():
    parser = argparse.ArgumentParser(description="공연 소개 이미지에서 정형 정보 추출")
    parser.add_argument("images", nargs="+", help="공연 소개 이미지 URL 또는 로컬 파일 경로 (여러 개 가능)")
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
            result = extract_poster_info(image, args.base_url, args.api_key)
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
