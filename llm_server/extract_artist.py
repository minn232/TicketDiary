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

few_shot_examples/ 폴더: 텍스트 지시만으론 안 고쳐지던 패턴 5개를 실제 포스터+정답으로 보여주는
멀티모달 few-shot 예시. _FEW_SHOT_EXAMPLES에서 참조하고, 매 요청 앞부분에 고정으로
붙는다 - 폴더의 이미지 파일을 지우거나 옮기면 실행이 깨지니 주의.

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

USER_PROMPT = "이 공연 포스터에서 위 규칙에 따라 출연 아티스트명을 추출해줘."

FEW_SHOT_DIR = Path(__file__).parent / "few_shot_examples"

# 텍스트 지시만으론 두 번 재타겟팅해도 안 고쳐지던 패턴 7개를 실제 이미지+정답으로 보여줌
# 각 항목: (파일명, concert_name 힌트, 정답 JSON) - 정답은 전부 포스터 직접 확인으로 확정한 것.
_FEW_SHOT_EXAMPLES: list[tuple[str, str, dict]] = [
    (
        # 패턴: 브랜드 로고만 있고 개별 이름이 아예 없으면 null (지어낸 placeholder 금지)
        "s2o_korea.gif",
        "S2O Korea (Korea Songkran Music Festival)",
        {
            "lineup": [{"artist": None, "performance_date": None}],
            "event_type": "UNKNOWN",
        },
    ),
    (
        # 패턴: "+"로 이어진 줄은 공연장 정보 - 진짜 아티스트명은 포스터 다른 곳에 크게 따로 있음
        "zutomayo.png",
        "ZUTOMAYO INTENSE Ⅱ, 坐·ZOMBIE CRAB LABO in Seoul FC presale 추가공연",
        {
            "lineup": [
                {"artist": "ZUTOMAYO", "performance_date": "2026-03-14"},
                {"artist": "ZUTOMAYO", "performance_date": "2026-03-15"},
            ],
            "event_type": "SOLO",
        },
    ),
    (
        # 패턴: 시리즈 브랜드명 X 날짜별 실제 아티스트 - 티켓 스텁처럼 작게 적힌 그 회차 실제 이름을 씀
        "wonder_weeks.jpg",
        "원더윅스 X 연합 불사일연 [부산]",
        {
            "lineup": [{"artist": "연합 불사일연", "performance_date": "2026-07-08"}],
            "event_type": "SOLO",
        },
    ),
    (
        # 패턴: 크고 화려한 테마/슬로건 문구에서 멈추지 말고 그 아래 실제 라인업까지 계속 읽기
        "cool_and_loud.png",
        "COOL & LOUD Rocking Sunday",
        {
            "lineup": [
                {"artist": "내귀에도청장치", "performance_date": "2026-07-12"},
                {"artist": "지프크락", "performance_date": "2026-07-12"},
                {"artist": "소소용", "performance_date": "2026-07-12"},
            ],
            "event_type": "FESTIVAL",
        },
    ),
    (
        # 패턴: 사진과 함께 크게 나온 메인 아티스트를 먼저 찾고, "FEAT." 같은 작은 보조 크레딧에만
        # 꽂혀서 메인을 놓치면 안 됨(둘 다 있으면 둘 다 포함)
        "fumi_stecxhno.gif",
        "KINETIC TEC Session 1: Hard Techno",
        {
            "lineup": [
                {"artist": "FUMI", "performance_date": "2026-08-08"},
                {"artist": "STECXHNO", "performance_date": "2026-08-08"},
            ],
            "event_type": "SOLO",
        },
    ),
    (
        # 패턴: 원칙2(브랜드/공연장명 제외)가 과잉발동해서, 제목·이미지 양쪽에 큼직하게
        # 인쇄된 명백한 아티스트명을 "in SEOUL" 같은 투어성 문구가 근처에 있다는 이유만으로
        # null 처리하던 회귀 반례 - 크고 반복적으로 인쇄된 이름이면 지우지 말 것
        "night_tempo.jpg",
        "NIGHT TEMPO in SEOUL: Future Funk, Future City",
        {
            "lineup": [{"artist": "NIGHT TEMPO", "performance_date": "2026-08-22"}],
            "event_type": "SOLO",
        },
    ),
    (
        # 패턴: 위와 반대 방향 - "클럽 투어"/"CLUB TOUR"처럼 투어 형식을 설명하는 단어가
        # 아티스트명 바로 옆에 있을 때 그 단어를 이름에 이어 붙여서 훼손하지 말 것
        # ("너드커넥션 클럽"이 아니라 "NERD CONNECTION") - 서로 다른 두 공연에서 반복 확인된 회귀
        "nerd_connection_club_tour.gif",
        "너드커넥션 클럽 투어: 파도의 고점 FINAL [서울]",
        {
            "lineup": [{"artist": "NERD CONNECTION", "performance_date": "2026-09-05"}],
            "event_type": "SOLO",
        },
    ),
]


# concert_name을 받지 않는 완전 고정 문자열로 둔다(공연마다 안 바뀜). vLLM의 prefix
# caching은 요청 간 동일한 접두어(토큰 0번부터)만 재사용하는데, 예전엔 concert_name이
# 이 프롬프트 맨 앞쪽(첫 문장 바로 뒤)에 끼어 있어서 공연마다 그 지점부터 뒤에 오는
# "핵심 원칙" 고정 블록 전체(이 프롬프트에서 제일 큰 부분)가 매번 캐시 미스로 처음부터
# 재계산됐다. concert_name은 대신 extract_artist_info의 user 메시지 쪽으로 옮겼다 -
# 이러면 system 메시지가 항상 바이트 단위로 동일해서 그 캐시를 매 요청 재사용할 수 있고,
# 실제로 매번 바뀌는 부분(공연 제목 + 포스터 이미지)만 user 메시지에 남는다.
def _build_system_prompt() -> str:
    return """\
당신은 공연 포스터에서 출연 아티스트명만 정확히 추출하는 어시스턴트입니다.
핵심 원칙 (반드시 순서대로 따르세요):
1. 아티스트명은 반드시 이미지 안에 실제로 인쇄되거나 표시된 텍스트에서만 가져오세요.
   얼굴/스타일/분위기로 유추한 본명이나 배경지식으로 답하지 마세요 - 이미지에 글자로
   쓰여 있지 않으면 null입니다. (포스터에 활동명만 있으면 활동명만 쓰고, 없는 본명으로
   바꾸지 마세요.)
2. 공연장/시설명, 주최·후원·티켓팅 로고, 페스티벌·이벤트·시리즈 브랜드명(예: "S2O",
   "Wonder Weeks")은 아티스트명이 아닙니다. 이런 텍스트만 보이고 개별 실명/활동명이
   안 보이면 null로 두세요 - 브랜드명을 잘못 등록하는 게 null보다 훨씬 나쁩니다(라인업은
   크롤링 단계에서 다시 채워지지만 잘못된 이름은 DB에 남습니다). 이런 브랜드/공연장명이
   부제·투어명·날짜와 "+"나 쉼표로 한 줄에 이어붙어 있으면(예: "부제+공연장 애칭+정식명칭")
   그 줄 전체를 후보에서 제외하고, 포스터 다른 곳에 인쇄된 진짜 아티스트명을 다시 찾으세요.
   사용자 메시지에 이 공연의 등록된 공연장(시설)명이 함께 주어지면, 포스터에 그 이름이
   보여도 절대 아티스트로 답하지 마세요 - 그건 어디서 열리는지에 대한 장소 정보입니다.
   **단, 이 원칙을 반대로 오적용하지 마세요**: 제목이나 이미지에 크고 반복적으로 인쇄된
   실제 이름은, 그 옆이나 뒤에 "투어/TOUR/CLUB/페스티벌/FESTIVAL/LIVE" 같은 단어가
   붙어 있다는 이유만으로 null 처리하거나 지우면 안 됩니다. 그런 단어는 투어·공연
   형식을 설명하는 것이지 이름의 일부가 아닙니다 - 이름과 형식 설명이 서로 다른 줄/
   글씨체로 인쇄돼 있으면 이름 부분만 정확히 떼어 쓰고, 형식 설명 단어를 이름에 이어
   붙이지 마세요(예: "NERD CONNECTION"과 "CLUB TOUR"가 분리돼 있으면 아티스트는
   "NERD CONNECTION"이지 "NERD CONNECTION 클럽"이 아닙니다). 등록된 공연장명과
   정확히 일치하지 않는 한, 크게 인쇄된 이름을 브랜드로 의심해서 지우는 쪽보다 이름
   그대로 살리는 쪽을 우선하세요.
3. 가장 크거나 장식적인 문구가 항상 아티스트명은 아닙니다. "~콘서트/투어/라이브" 앞뒤
   이름을 우선하고, 부제/앨범명/투어명과 혼동하지 마세요. 아티스트명에 캐치프레이즈가
   붙어 한 배너로 인쇄됐다면 이름 부분만 뽑으세요. 반대로 "+"/쉼표로 이어진 목록 하나를
   전체 라인업이라 단정하지 말고, 더 크고 또렷하게 인쇄된 실제 아티스트명이 따로 있는지
   확인하세요.
4. 사용자 메시지의 공연 제목을 적극 참고하세요(최후 수단 아님). 제목은 흔히 "아티스트명:
   부제" 형식이라 그대로 답이 되는 경우가 많습니다(예: "9와 숫자들: 99%, Best"). 단, 제목
   맨 앞이 주최사/시리즈/페스티벌 브랜드명이고 실제 공연자명이 뒤에 따로 있는 경우도
   흔하니, 어느 부분이 실제 "사람/팀 이름"인지 판단하세요. 이미지에서 특정 불가능할 때는
   이 판단을 최종 답으로 써도 되지만, 이미지에 뚜렷이 다른 이름이 있으면 이미지를 따르세요.
5. 위 방법으로도 특정할 수 없으면 추측하지 말고 null로 두세요. "Various Artists", "TBA"
   같은 안내 문구를 스스로 만들어 넣지 마세요 - 포스터에 없다면 이것도 지어낸 값입니다.
6. 라인업과 별개로 event_type을 답하세요:
   - "SOLO": 아티스트/팀이 하나만 크게 나오고, 다른 이름이 있어도 콜라보/듀엣 상대 정도
   - "FESTIVAL": 서로 다른 팀이 2개 이상 확인되거나(로고 나열, 날짜별/스테이지별 다수
     출연진), 공연명 자체가 페스티벌 성격인 경우
   - "UNKNOWN": 판단하기 어려운 경우(라인업 미공개 티저 등)
   라인업에 서로 다른 이름을 1개만 넣었으면서 FESTIVAL로 답하지 마세요.

라인업 작성 방법:
- 출연 가수/팀마다 artist(가수명)·performance_date(출연 날짜, YYYY-MM-DD, 모르면 null)
  로 구성된 배열을 만드세요. 같은 이름이 모든 날짜에 반복된다면 원칙 2의 브랜드/시리즈명
  신호일 수 있으니, 날짜 칸 근처의 실제 팀명을 다시 찾고 그래도 못 찾으면 반복해서 채우지
  마세요(같은 오답 반복이 한 번 놓치는 것보다 나쁩니다 - null 하나만 남기세요).
- 이미지에 아티스트를 특정할 문구가 전혀 없어도(인물 사진만 있는 포스터 포함) null로
  두기 전에 먼저 원칙 4로 제목을 확인하세요 - "아티스트명 단독 콘서트/투어" 형식이면
  그 이름을 쓰세요. 제목에도 힌트가 없을 때만 진짜 블라인드로 보고 항목 1개,
  artist=null, performance_date=null로 둡니다.
- "A x B", "A & B", "A with B", "A·B", "A+B"처럼 이어진 콜라보/듀엣 표기는 각각 별도
  항목으로 나누세요(예: "김현수 x 이벼리" → 두 항목). 하나의 고정 유닛 이름이 명백하면
  합쳐도 되지만 애매하면 나누는 쪽을 기본으로 하세요. 나누기 전 각 조각이 정말 "사람/팀
  이름"인지 원칙 2를 다시 확인하세요(공연장/시설명 조각이 섞였으면 콜라보가 아닙니다).
- 같은 출연진이 한글명/영문명으로 각각 표시돼도 두 팀으로 나누지 말고 하나로 합치되,
  artist에는 두 표기를 이어 붙이지 말고 그중 하나만 고르세요(라인업 줄에 쓰인 표기
  우선, 애매하면 아무거나) - 합친 문자열은 검색/팔로우 매칭에 안 걸립니다.
- 한자/가나/키릴 문자 등 한글도 로마자도 아닌 표기만 있고 제목에 같은 대상의 로마자
  표기가 있다면(예: 이미지 "名誉×伝説", 제목 "MEIYO DENSETSU") 로마자 표기를 최종 답으로
  쓰세요 - 검색/매칭에 더 일관적입니다. 제목에 대응 표기가 없으면 억지로 바꾸지 말고
  이미지의 원어 표기를 그대로 쓰세요.

반드시 주어진 JSON 스키마 형식으로만 답하세요.
"""


# 백엔드 app/models/concert.py의 EventType enum과 값을 정확히 맞춰야 함(변환 없이 그대로
# 웹훅에 실어 보냄) - 값을 바꾸면 그쪽도 같이 바꿀 것
EVENT_TYPES = ["SOLO", "FESTIVAL", "UNKNOWN"]

ARTIST_LINEUP_SCHEMA = {
    "type": "object",
    "properties": {
        "lineup": {
            "type": "array",
            "items": LINEUP_ENTRY_SCHEMA,
        },
        "event_type": {"type": "string", "enum": EVENT_TYPES},
    },
    "required": ["lineup", "event_type"],
    "additionalProperties": False,
}


def load_image(image: str) -> Image.Image:
    if image.startswith("http://") or image.startswith("https://"):
        resp = requests.get(image, timeout=30)
        resp.raise_for_status()
        return Image.open(io.BytesIO(resp.content)).convert("RGB")
    return Image.open(image).convert("RGB")


def image_to_data_uri(im: Image.Image) -> str:
    buf = io.BytesIO()
    im.save(buf, format="PNG")
    data = base64.b64encode(buf.getvalue()).decode("utf-8")
    return f"data:image/png;base64,{data}"


def _user_turn(concert_name: str | None, image: Image.Image, venue: str | None = None) -> dict:
    lines = []
    if concert_name:
        lines.append(f'이 공연의 제목은 "{concert_name}"입니다.')
    if venue:
        lines.append(f'이 공연이 열리는 공연장(시설) 이름은 "{venue}"로 등록되어 있습니다.')
    lines.append(USER_PROMPT)
    user_text = "\n\n".join(lines)
    return {
        "role": "user",
        "content": [
            {"type": "text", "text": user_text},
            {"type": "image_url", "image_url": {"url": image_to_data_uri(image)}},
        ],
    }


# few-shot 턴을 매번 새로 만들지 않고 최초 1회만 구성해 재사용 - 이미지 재인코딩도 없고,
# system 메시지처럼 매 요청 바이트 단위로 동일해야 prefix caching이 이 구간까지 재사용된다.
_few_shot_messages_cache: list[dict] | None = None


def _build_few_shot_messages() -> list[dict]:
    global _few_shot_messages_cache
    if _few_shot_messages_cache is None:
        messages: list[dict] = []
        for filename, concert_name, answer in _FEW_SHOT_EXAMPLES:
            im = load_image(str(FEW_SHOT_DIR / filename))
            messages.append(_user_turn(concert_name, im))
            messages.append({"role": "assistant", "content": json.dumps(answer, ensure_ascii=False)})
        _few_shot_messages_cache = messages
    return _few_shot_messages_cache


def extract_artist_info(
    image: str, concert_name: str | None, base_url: str, api_key: str = "EMPTY", venue: str | None = None
) -> dict:
    client = OpenAI(base_url=base_url, api_key=api_key)

    im = load_image(image)

    response = client.chat.completions.create(
        model=MODEL_NAME,
        messages=[
            {"role": "system", "content": _build_system_prompt()},
            *_build_few_shot_messages(),
            _user_turn(concert_name, im, venue),
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
    parser.add_argument("--venue", default=None, help="공연장(시설)명 (원칙 2번 - 공연장명 오인 방지용, 생략 가능)")
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
            result = extract_artist_info(image, args.concert_name, args.base_url, args.api_key, args.venue)
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
