"""
inference.py가 반환한 값(모델 출력 그대로, 형태가 느슨할 수 있음)을 백엔드 웹훅이
기대하는 정확한 JSON 형태로 다듬는 계층.

응답 스키마는 고정 계약으로 잠그지 않고 "LLM 출력 형태에 맞춰 백엔드가 조정"하기로
합의됐으므로(docs/LLM_INTEGRATION_MEETING_QUESTIONS.md 3번 참고), 실제 모델 출력을
보고 나서 손댈 곳은 inference.py가 아니라 이 파일이 되어야 한다.
"""

from datetime import date, datetime


def _to_date_string(value) -> str | None:
    if value is None:
        return None
    if isinstance(value, (date, datetime)):
        return value.strftime("%Y-%m-%d")
    return str(value)


def normalize_crawl_result(raw: dict) -> dict:
    body: dict = {}

    if raw.get("timetable") is not None:
        body["timetable"] = raw["timetable"]
    if raw.get("prices") is not None:
        body["prices"] = raw["prices"]
    if raw.get("venue_layout") is not None:
        body["venue_layout"] = raw["venue_layout"]
    if raw.get("ticketing_date") is not None:
        body["ticketing_date"] = _to_date_string(raw["ticketing_date"])
    if raw.get("delivery_date") is not None:
        body["delivery_date"] = _to_date_string(raw["delivery_date"])
    if raw.get("artist_name"):
        body["artist_name"] = list(raw["artist_name"])

    return body


def normalize_artist_list(raw) -> list[str]:
    if raw is None:
        return []
    return [str(name) for name in raw]


def normalize_diary_text(raw) -> str:
    return str(raw) if raw is not None else ""
