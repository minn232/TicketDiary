"""Qwen2.5-VL 출력에 강제할 JSON 스키마 정의 (vLLM response_format: json_schema 용)."""

DATE_PATTERN = r"^\d{4}-\d{2}-\d{2}$"
TIME_PATTERN = r"^([01]\d|2[0-3]):[0-5]\d$"

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
        "timetable": {
            "anyOf": [
                {"type": "array", "items": TIMETABLE_ENTRY_SCHEMA},
                {"type": "null"},
            ]
        },
        "lineup": {
            "type": "array",
            "items": LINEUP_ENTRY_SCHEMA,
        },
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
    "required": ["timetable", "lineup", "ticketing_date", "ticket_delivery_date", "ticket_prices", "other_info"],
    "additionalProperties": False,
}
