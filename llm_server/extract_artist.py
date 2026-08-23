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

# 텍스트 지시만으론 두 번 재타겟팅해도 안 고쳐지던 패턴 5개를 실제 이미지+정답으로 보여줌
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
   인물의 얼굴, 스타일, 분위기를 보고 당신이 이미 알고 있는 실제 이름(본명 등)이나
   배경지식으로 답하지 마세요 - 그 이름이 이미지 안에 글자로 쓰여 있지 않다면 절대 쓰지
   말고 null로 두세요. (예: 포스터에 활동명만 쓰여 있으면 활동명만 답하고, 이미지에 없는
   본명으로 바꿔 쓰지 마세요.)
2. 공연장/시설명(예: "OO홀", "OO체육관", "OO아트센터", "OO돔" 등)이나 주최사/후원사/
   티켓팅 플랫폼 로고, 페스티벌·이벤트·공연 시리즈 브랜드명(예: "S2O", "카스쿨 페스티벌",
   "Wonder Weeks")은 아티스트명이 아닙니다. 이런 텍스트만 크게 보이고 개별 가수·팀의
   실명/활동명은 안 보이면 브랜드명을 대신 넣지 말고 null로 두세요 - 브랜드명을 아티스트로
   잘못 등록하는 게 null보다 훨씬 나쁩니다(라인업을 못 뽑아도 이후 크롤링 단계에서 다시
   채워지지만, 잘못된 이름은 그대로 DB에 남습니다). 이런 브랜드·공연장명은 부제/투어명/
   날짜와 "+"나 쉼표로 한 줄에 이어붙어 나오기도 합니다(예: "「부제」+공연장 애칭+공연장
   정식명칭") - 그 줄에 공연장/시설명이나 브랜드명이 하나라도 섞여 있으면 콜라보 라인업으로
   보고 조각내지 말고, 줄 전체를 후보에서 제외한 뒤 포스터의 다른 위치에 별도로 인쇄된
   진짜 아티스트명을 다시 찾으세요.
3. 이미지 안에 크기/스타일이 다른 여러 문구가 함께 있을 때, 가장 크거나 장식적인 문구가
   항상 아티스트명은 아닙니다. "~단독공연", "~콘서트", "~라이브", "~투어" 같은 문구
   바로 앞이나 뒤에 오는 이름을 아티스트명 후보로 우선하고, 그 옆에 있는 부제/앨범명/
   투어명/EP명과 혼동하지 마세요. 투어명이 아티스트명 뒤에 캐치프레이즈/슬로건이 붙어
   하나의 큰 배너로 인쇄된 경우("아티스트명 캐치프레이즈! TOUR"처럼)엔 그 안에서 실제
   아티스트명 부분만 뽑고 슬로건까지 통째로 붙여 쓰지 마세요 - 포스터 다른 곳(사진 라벨
   등)에 아티스트명만 단독으로 더 깔끔하게 적혀 있으면 그 표기를 우선하세요. 반대로,
   포스터 안에서 "+"나 쉼표로 이어진 목록 하나를 찾았다고 해서 그게 전체 라인업이라고
   단정하지 마세요 - 포스터의 다른 위치(대개 가장 크고 또렷하게 인쇄된, 장식체가 아닌
   글자)에 실제 출연 아티스트명이 별도로 있는지 반드시 다시 확인하고, 있다면 그 이름도
   라인업에 포함하세요.
4. 사용자 메시지에 함께 주어지는 공연 제목은 처음부터 적극적으로 참고하세요(이미지에서 못 찾았을 때만
   보는 최후 수단이 아닙니다). 제목은 흔히 "아티스트명: 부제" 또는 "아티스트명 콘서트:
   부제" 형식이라 제목 안에 아티스트명이 그대로 들어있는 경우가 많습니다(예: "9와
   숫자들: 99%, Best"). 이미지 안에 여러 후보 문구가 있어 어느 게 아티스트명인지
   헷갈릴 때는 제목과 일치하거나 제목에 포함된 후보를 우선하세요. 단, 제목 맨 앞이
   방송사/주최사/공연 시리즈나 페스티벌 브랜드명("OO대기획", "OO상상마당", "OO
   LIVE SERIES", "OO페스타", "마티네 콘서트" 등)이고 실제 공연자명은 쉼표 뒤나
   뒷부분에 따로 있는 경우도 흔하니, 제목 맨 앞 글자만 기계적으로 자르지 말고 어느
   부분이 실제 "사람/팀 이름"인지 판단하세요. 이미지에서 아티스트명을 전혀 특정할 수
   없을 때는 이 판단을 그대로 최종 답으로 써도 됩니다(추측이 아니라 미리 제공된 정보를
   쓰는 것). 다만 이미지에 뚜렷이 다른 이름이 적혀 있어 명백히 모순되면 이미지 쪽을
   따르세요.
5. 위 방법으로도 특정할 수 없는 정보는 추측하지 말고 null로 두세요. "Various Artists",
   "TBA", "아티스트 미정" 같은 일반적인 안내 문구를 스스로 만들어 넣지 마세요 - 포스터에
   그 문구가 실제로 인쇄되어 있지 않다면 이것도 지어낸 값입니다.
6. 라인업과 별개로, 이 공연이 한 팀/아티스트의 단독 공연인지 여러 팀이 함께 출연하는
   페스티벌/합동공연인지도 event_type으로 답하세요:
   - "SOLO": 포스터에 아티스트/팀이 하나만 크게 나오고, 다른 이름이 있어도 그 한 팀과의
     콜라보/듀엣 상대 정도인 경우
   - "FESTIVAL": 서로 다른 여러 팀의 이름/로고가 나란히 나열돼 있거나, 날짜별/스테이지별
     타임테이블 형식으로 다수 출연진이 있거나, 공연명 자체가 페스티벌/합동공연 성격인 경우.
     정확히 몇 팀 이상이어야 한다는 기준은 없고, 서로 다른 팀이 2개 이상 확인되면 충분합니다
   - "UNKNOWN": 포스터/제목만으로 위 둘 중 어느 쪽인지 판단하기 어려운 경우(예: 라인업이
     전혀 공개되지 않은 티저 포스터)
   이 판단은 실제로 라인업에 몇 팀을 뽑았는지와 앞뒤가 맞아야 합니다 - 라인업에 서로 다른
   이름을 1개만 넣었으면서 event_type을 FESTIVAL로 답하지 마세요.

라인업 작성 방법:
- 출연하는 가수/팀마다 한 항목씩, artist(가수명)와 performance_date(출연 날짜, YYYY-MM-DD,
  모르면 null)로 구성된 배열을 만드세요. 날짜마다 실제로 다른 이름이 아니라 같은 이름이
  모든 날짜에 반복된다면, 그건 원칙 2의 브랜드/시리즈명일 가능성이 높다는 신호입니다 -
  각 날짜 칸 근처에 따로 적힌 실제 팀명을 다시 찾아보고, 그래도 못 찾으면 그 이름을
  여러 날짜에 반복해서 채우지 마세요(같은 오답을 여러 번 반복 등록하는 게 한 번 놓치는
  것보다 나쁩니다 - 이 경우 하나만 null로 남기세요).
- 이미지 안에 아티스트를 특정할 문구가 전혀 없는 경우(글자 없이 인물 사진만 있는 포스터
  포함) null로 두기 전에 **먼저 원칙 4에 따라 공연 제목을 확인**하세요. 제목이 "아티스트명
  단독 콘서트/투어/라이브" 같은 형식이라 명확한 아티스트/그룹명이 있다면, 이미지에 글자가
  없더라도 그 이름으로 항목 하나를 만들어 답하고 null로 두지 마세요(예: 포스터가 인물
  사진뿐이어도 제목이 "LET ME KNOW 1st album release TOUR"이면 artist="LET ME KNOW").
  제목에도 아티스트를 특정할 힌트가 없는 경우(여러 팀이 나오는 페스티벌인데 라인업 자체가
  아직 미발표인 경우 등)에만 진짜 블라인드 라인업으로 보고 항목 1개, artist=null,
  performance_date=null로 둡니다.
- "A x B", "A & B", "A with B", "A·B", "A+B"처럼 서로 다른 두 사람/팀 이름이 기호로
  이어진 콜라보/듀엣 표기는 하나의 문자열로 합치지 말고 각각 별도 라인업 항목으로
  나누세요(예: "김현수 x 이벼리"는 artist="김현수" 항목과 artist="이벼리" 항목 두 개).
  붙여서 저장하면 나중에 한 사람만 검색/팔로우할 때 안 걸립니다. 단, 이게 실제로 하나의
  고정된 팀/그룹 이름의 일부인 게 명백하면(예: 포스터에 하나의 로고/사진으로 함께
  소개되는 고정 유닛) 합쳐도 됩니다 - 애매하면 나누는 쪽을 기본으로 하세요. 나누기 전에
  이어진 조각 하나하나가 정말 "사람/팀 이름"인지 원칙 2를 다시 확인하세요(공연장/시설명
  조각이 섞여 있으면 콜라보가 아니라 상세정보 줄일 가능성이 높습니다).
- 같은 출연진이 한글명과 영문명(또는 그 외 서로 다른 표기)으로 각각 표시돼 있다고 해서
  서로 다른 두 팀으로 착각해 항목을 두 개 만들지 마세요. 최종 목록을 만들기 전에 지금까지
  나온 이름들을 서로 비교해 같은 인물/팀을 가리키는 표기가 없는지 확인하세요. 동일
  인물/팀으로 판단되면 항목 하나로 합치되, artist에는 **두 표기를 이어 붙이지 말고 그중
  하나만** 고르세요(라인업 목록 줄에 쓰인 표기를 우선하고, 우열을 가리기 애매하면 아무
  거나 하나) - 두 표기를 합친 문자열은 검색/팔로우 매칭에 안 걸려서 오히려 못 쓰게 됩니다.
- 이미지에 한자/가나/키릴 문자 등 한글도 로마자도 아닌 외국어 표기만 있고, 함께 주어진
  공연 제목에 같은 대상을 가리키는 로마자 표기가 있다면(예: 이미지엔 "名誉×伝説"만,
  제목엔 "MEIYO DENSETSU"), 이미지 표기 대신 **제목의 로마자 표기를 최종 답으로** 쓰세요
  (즉 "名誉×伝説"이 아니라 "MEIYO DENSETSU") - 외국어 원어 표기보다 로마자 표기가 검색/
  매칭에 더 일관적이기 때문입니다. 제목에 대응하는 로마자 표기가 없으면(원어 표기만
  있고 로마자로 뭐라 하는지 알 수 있는 정보가 없으면) 억지로 로마자로 바꾸지 말고 이미지에
  실제로 적힌 원어 표기를 그대로 쓰세요 - 모르는 로마자 표기를 지어내지 마세요.

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


def _user_turn(concert_name: str | None, image: Image.Image) -> dict:
    user_text = USER_PROMPT
    if concert_name:
        user_text = f'이 공연의 제목은 "{concert_name}"입니다.\n\n{USER_PROMPT}'
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


def extract_artist_info(image: str, concert_name: str | None, base_url: str, api_key: str = "EMPTY") -> dict:
    client = OpenAI(base_url=base_url, api_key=api_key)

    im = load_image(image)

    response = client.chat.completions.create(
        model=MODEL_NAME,
        messages=[
            {"role": "system", "content": _build_system_prompt()},
            *_build_few_shot_messages(),
            _user_turn(concert_name, im),
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
