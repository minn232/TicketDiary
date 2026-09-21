"""extract_from_timetable.py 전용 JSON 스키마 (vLLM response_format: json_schema 용).

schema.py의 POSTER_INFO_SCHEMA에서 타임테이블 추출에 쓰는 필드만 남기고, timetable 항목의 시각을
모델이 직접 HH:MM으로 바꿔 쓰는 time 대신 블록에 인쇄된 시각 글자를 그대로 옮기는 time_text로 받는다.
시작 시각(HH:MM)은 extract_from_timetable.py가 time_text에서 뽑는다.

time_text로 바꾼 이유(2026-09-21): time을 HH:MM으로 받으면 모델이 블록 안의 시각("12:50 - 13:30 (40')")
대신 표 옆 시간축 눈금(12, 13, 14 ...)을 읽고 정각으로 채우는 경우가 많았다(sbmf, yes24_55774, gmf2025
실측). 인쇄된 글자를 그대로 옮기게 하면 블록 안의 글자를 읽도록 유도할 수 있다.

나머지 필드(event_category ~ timetable_present)는 POSTER_INFO_SCHEMA와 같은 이름·순서로 둔다 - 추출
순서를 유도하는 스캐폴딩이라 결과에는 쓰지 않지만, time_text 변경의 효과만 비교하려고 그대로 유지했다.
"""

from schema import DATE_PATTERN, LINEUP_ENTRY_SCHEMA, LINEUP_MAX_ITEMS, TIMETABLE_MAX_ITEMS

# 인쇄된 시각 글자는 길어야 "12:50 - 13:30 (40')" 정도다. 상한을 둬서 모델이 이 필드에서 반복
# 루프에 빠져도 곧 닫히게 한다(vLLM strict 디코딩은 maxLength를 생성 시점에 강제한다).
TIME_TEXT_MAX_LENGTH = 40

TIMETABLE_TEXT_ENTRY_SCHEMA = {
    "type": "object",
    "properties": {
        "performance_date": {"anyOf": [{"type": "string", "pattern": DATE_PATTERN}, {"type": "null"}]},
        "time_text": {"type": "string", "maxLength": TIME_TEXT_MAX_LENGTH},
        "artist": {"anyOf": [{"type": "string"}, {"type": "null"}]},
        "stage": {"type": ["string", "null"]},
    },
    "required": ["performance_date", "time_text", "artist", "stage"],
    "additionalProperties": False,
}

TIMETABLE_INFO_SCHEMA = {
    "type": "object",
    "properties": {
        "event_category": {"type": "string", "enum": ["festival", "other"]},
        "lineup_source": {
            "anyOf": [
                {"type": "string", "enum": ["lineup_section", "timetable_only", "none"]},
                {"type": "null"},
            ]
        },
        "lineup_artist_count": {"anyOf": [{"type": "integer", "minimum": 0}, {"type": "null"}]},
        "lineup": {"type": "array", "items": LINEUP_ENTRY_SCHEMA, "maxItems": LINEUP_MAX_ITEMS},
        "timetable_layout": {"type": "string", "enum": ["grid", "list", "none"]},
        "timetable_present": {"type": "boolean"},
        "timetable": {
            "anyOf": [
                {"type": "array", "items": TIMETABLE_TEXT_ENTRY_SCHEMA, "maxItems": TIMETABLE_MAX_ITEMS},
                {"type": "null"},
            ]
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
    ],
    "additionalProperties": False,
}
