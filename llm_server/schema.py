"""Qwen2.5-VL 출력에 강제할 JSON 스키마 정의 (vLLM response_format: json_schema 용)."""

# 연도를 "20\d{2}"로 제한한다(2000~2099년) - 그냥 "\d{4}"였을 때 모델이 가끔 "1225-12-25"처럼
# 자릿수만 맞고 연도가 말이 안 되는 값을 뱉는 게 실측으로 확인됐다. vLLM의 json_schema
# strict 강제 디코딩은 이 정규식을 생성 시점에 직접 적용하므로, 패턴을 좁히면 애초에 그런
# 토큰을 고를 수 없게 돼 후처리 검증 없이 원천 차단된다.
DATE_PATTERN = r"^20\d{2}-\d{2}-\d{2}$"
TIME_PATTERN = r"^([01]\d|2[0-3]):[0-5]\d$"

# 배치(조각) 응답 1건당 배열 길이 상한(2026-09-14). 모델이 같은 이름을 끝없이 반복하는 루프에
# 빠지면(사운드플래닛 실측: 아티스트 36번 중 고유 7개) 응답이 max_tokens(20000)까지 이어져
# 잘리고, 타일 1장까지 쪼개도 잘려 이미지 전체 추출이 실패했다. vLLM strict 디코딩은 maxItems를
# 생성 시점에 강제하므로(실측 확인), 루프에 빠져도 상한에서 배열이 닫히고 다음 필드로 넘어간다.
# 상한까지 채워도 약 6,000토큰이다. 지금까지 배치 하나가 낸 lineup은 최대 41개였고, 조각끼리
# 겹쳐 읽으므로 실제 항목이 상한에 잘릴 위험은 작다.
LINEUP_MAX_ITEMS = 60
TIMETABLE_MAX_ITEMS = 80

TIMETABLE_ENTRY_SCHEMA = {
    "type": "object",
    "properties": {
        "performance_date": {"anyOf": [{"type": "string", "pattern": DATE_PATTERN}, {"type": "null"}]},
        "time": {"anyOf": [{"type": "string", "pattern": TIME_PATTERN}, {"type": "null"}]},
        "artist": {"anyOf": [{"type": "string"}, {"type": "null"}]},
        "stage": {"type": ["string", "null"]},
    },
    "required": ["performance_date", "time", "artist", "stage"],
    "additionalProperties": False,
}

LINEUP_ENTRY_SCHEMA = {
    "type": "object",
    "properties": {
        "artist": {"anyOf": [{"type": "string"}, {"type": "null"}]},
        "performance_date": {"anyOf": [{"type": "string", "pattern": DATE_PATTERN}, {"type": "null"}]},
    },
    "required": ["artist", "performance_date"],
    "additionalProperties": False,
}

TICKET_PRICE_SCHEMA = {
    "type": "object",
    "properties": {
        "seat_type": {"type": "string"},
        "price": {"type": "integer", "minimum": 0},
    },
    "required": ["seat_type", "price"],
    "additionalProperties": False,
}

POSTER_INFO_SCHEMA = {
    "type": "object",
    "properties": {
        # 순서 수정(2026-08-27): lineup을 timetable보다 먼저 선언한다. vLLM의 json_schema
        # strict 강제 디코딩(outlines/xgrammar 계열)은 object의 키를 "properties에 선언된
        # 순서대로" 생성한다 - 즉 timetable이 먼저 선언돼 있으면 모델은 lineup을 아직 한 글자도
        # 쓰기 전에 timetable부터 채워야 했다. "timetable의 artist는 반드시 lineup에 있는
        # 이름과 동일한 표기를 쓰라"는 지시를 프롬프트로만 줘도 실제로는 지켜지지 않고(부스
        # 코드 "N21"/"S6" 같은, lineup에 없는 이름이 timetable에 섞여 나오는 게 실측으로
        # 확인됨) - lineup을 먼저 생성하게 하면 모델이 timetable의 artist를 쓸 때 이미 만든
        # lineup 목록을 문맥으로 참고할 수 있다. 그래도 모델이 안 지킬 수 있으니
        # extract_poster.py의 _merge_results가 lineup에 없는 이름의 timetable 항목을 강제로
        # 걸러내는 하드 필터도 추가했다(둘 다 있어야 함 - 순서는 확률을 높이는 것뿐).
        # 순서 수정(2026-09-07): 아티스트 누락 대응. 강제 디코딩이 선언 순서대로 생성한다는
        # 같은 성질을 한 단계 더 활용해, lineup을 쓰기 전에 (1) 라인업이 있는지 (2) 몇 명인지를
        # 먼저 답하게 하는 스캐폴딩 필드를 앞에 둔다. 모델은 이름을 한 글자도 쓰기 전에 "이
        # 이미지에는 N명이 있다"고 스스로 확정한 뒤 그 N개를 채우게 되므로, 중간에 훑기를 멈춰
        # 뒷부분 아티스트를 통째로 빠뜨리는 실패가 줄어든다(개수라는 목표치가 문맥에 남아 있음).
        # 뒤집어 말하면 없는 이름을 지어내 개수를 맞출 위험이 생기므로, SYSTEM_PROMPT 3단계에서
        # "실제 인쇄된 이름이 더 적으면 2단계 추측이 틀린 것"이라고 명시하고 extract_poster.py의
        # _filter_lineup_noise가 자리표시자 이름을 코드 레벨에서 한 번 더 걸러낸다.
        # 이 두 필드와 timetable_present는 추출 절차를 유도하기 위한 스캐폴딩일 뿐이라
        # _merge_results의 최종 반환값에는 넣지 않는다(백엔드 계약 6개 키 유지).
        # 라인업을 "어디서 읽었는지"를 이름보다 먼저 확정하게 한다. 실측에서
        # 전용 라인업 섹션(43팀)이 페이지에 버젓이 있는데도 최종 lineup이 타임테이블 유래 20팀
        # (합동 공연을 한 블록으로 쓴 "C JAMM x Black Nut" 같은 표기까지 그대로)으로 채워지는
        # 일이 있었다 - set(lineup) - set(timetable)이 공집합인 것으로 확인. 배치마다 출처를
        # 답하게 해두면 _merge_results가 "라인업 섹션을 본 배치"의 답을 우선 채택할 수 있다.
        # 2026-09-07(2차): 예전에는 이 앞에 lineup_present(불리언)가 따로 있었다 - "이름이 있는가"를
        # 먼저 못박는 스캐폴딩이었는데, 여기 "none"이 곧 그 false와 같은 뜻이라 정보가 완전히
        # 겹쳤다. 게다가 둘을 스키마에서 묶어두지 않아 (present=true, source="none") 같은 모순된
        # 답이 나올 수 있었고, 코드는 어차피 이 필드만 읽고 있었다. 하나로 합친다.
        # 2026-09-13: 페스티벌/그 외 공연 구분을 맨 앞에 둔다 - 이 답에 따라 뒤 필드의 추출 절차가
        # 달라지므로(SYSTEM_PROMPT 0단계), 이름을 쓰기 전에 먼저 확정되어 문맥에 남아야 한다.
        # 그 외 공연("other")은 라인업 구역이 없어 lineup_source를 null로 두므로 nullable로 바꿨다.
        # 백엔드의 event_type(SOLO/FESTIVAL/UNKNOWN, extract_artist.py)과는 별개인 스캐폴딩 필드라
        # 이름과 값을 일부러 다르게 둔다(normalize.py가 event_type 키를 읽기 때문).
        "event_category": {"type": "string", "enum": ["festival", "other"]},
        "lineup_source": {
            "anyOf": [
                {"type": "string", "enum": ["lineup_section", "timetable_only", "none"]},
                {"type": "null"},
            ]
        },
        "lineup_artist_count": {
            "anyOf": [
                {"type": "integer", "minimum": 0},
                {"type": "null"},
            ]
        },
        "lineup": {
            "type": "array",
            "items": LINEUP_ENTRY_SCHEMA,
            "maxItems": LINEUP_MAX_ITEMS,
        },
        # timetable을 쓰기 직전에 "시간표가 있는지"를 먼저 확정하게 한다 - timetable=null(시간표
        # 자체가 없음)과 []( 있지만 이 구간엔 항목이 안 보임)의 구분이 배치별로 흔들리던 것을
        # 명시적인 불리언으로 한 번 더 붙잡아 준다(_merge_results가 이 값을 함께 본다).
        # 2026-09-14: 이 조각에 보이는 시간표 형태. 좌우로 자른 조각으로는 격자형 시간표(가로 무대 열 x
        # 세로 시간축)를 거의 못 읽어서(사운드플래닛·그랜드민트 실측 정답 확보 0~1개), "grid"로 답한 배치
        # 구간은 extract_poster_info가 2차로 전체 폭 그대로 촘촘하게 다시 잘라 추출한다. 스캐폴딩이라
        # 최종 결과에는 안 들어간다.
        # 2026-09-25: 자동 2차 추출은 없앴다(시간표 구간은 호출하는 쪽이 timetable_ranges로 준다). 지금은
        # 추출 절차를 유도하는 스캐폴딩으로만 남아 있다.
        "timetable_layout": {"type": "string", "enum": ["grid", "list", "none"]},
        "timetable_present": {"type": "boolean"},
        "timetable": {
            "anyOf": [
                {"type": "array", "items": TIMETABLE_ENTRY_SCHEMA, "maxItems": TIMETABLE_MAX_ITEMS},
                {"type": "null"},
            ]
        },
        # 버그 수정(2026-08-27): 예전엔 {phase,date} 객체 배열로 강제돼 있었는데, SYSTEM_PROMPT는
        # "여러 단계 중 가장 이른 날짜 하나만 문자열로 답하라"고 지시하고 normalize.py/백엔드
        # 계약(schemas.py CrawlResultCallback.ticketing_date: str|None)도 전부 단일 문자열을
        # 기대해서 셋이 서로 어긋나 있었다 - 실제로 강제 디코딩 스키마와 자연어 지시가 맞지 않으니
        # 모델이 사실상 항상 null만 반환하는 상태였다(38개 테스트 결과 전부 null 확인). 프롬프트/
        # 백엔드에 맞춰 단일 날짜 문자열로 되돌린다.
        "ticketing_date": {
            "anyOf": [
                {"type": "string", "pattern": DATE_PATTERN},
                {"type": "null"},
            ]
        },
        "ticket_delivery_date": {
            "anyOf": [
                {"type": "string", "pattern": DATE_PATTERN},
                {"type": "null"},
            ]
        },
        "ticket_prices": {
            "anyOf": [
                {"type": "array", "items": TICKET_PRICE_SCHEMA},
                {"type": "null"},
            ]
        },
        "other_info": {
            "type": "object",
            "properties": {
                "food_allowed": {
                    "anyOf": [
                        {"type": "string", "enum": ["가능", "불가능", "일부허용"]},
                        {"type": "null"},
                    ]
                },
            },
            "required": ["food_allowed"],
            "additionalProperties": False,
        },
    },
    "required": [
        "event_category",
        "lineup_source",
        "lineup_artist_count",
        "lineup",
        "timetable_layout",
        "timetable_present",
        "timetable",
        "ticketing_date",
        "ticket_delivery_date",
        "ticket_prices",
        "other_info",
    ],
    "additionalProperties": False,
}
