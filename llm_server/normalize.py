"""inference.py가 반환한 값(모델 출력 그대로, 형태가 느슨할 수 있음)을 백엔드 웹훅이
기대하는 정확한 JSON 형태로 다듬는 계층.

응답 스키마는 고정 계약으로 잠그지 않고 "LLM 출력 형태에 맞춰 백엔드가 조정"하기로
합의됐으므로(docs/LLM_INTEGRATION_MEETING_QUESTIONS.md 3번 참고), 실제 모델 출력을
보고 나서 손댈 곳은 inference.py가 아니라 이 파일이 되어야 한다.

LLM팀 실제 SYSTEM_PROMPT(Qwen2.5-VL) + vLLM response_format(json_schema, POSTER_INFO_SCHEMA)
강제 출력 포맷 기준(2026-08-18 ticketing_date 추가):
{
    "timetable": [{"performance_date": "2026-09-19", "time": "18:00", "artist": "...", "stage": "MAIN"}] | null,
    "lineup": [{"artist": "...", "performance_date": "2026-09-19"}],   # 항상 배열(null 아님)
    "ticketing_date": "2026-08-25" | null,
    "ticket_delivery_date": "2026-09-10" | null,
    "ticket_prices": [{"seat_type": "VIP", "price": 198000}] | null,
    "other_info": {"food_allowed": "가능"|"불가능"|"일부허용"|null},   # 객체 자체는 항상 존재
}
POSTER_INFO_SCHEMA는 최상위에 additionalProperties: False + 위 6개 키만 required라서
venue_layout은 지금 이 경로로는 나올 수 없음(안 쓰기로 결정해 매핑 자체를 없앰).
ticketing_date는 크롤링 "완료" 판정에 쓰이는 필드라(crawler.py의 Concert.ticketing_date)
이게 안 채워지면 같은 공연이 24시간 쿨다운마다 계속 재크롤링됨 - 이번에 스키마에 추가되기
전까지 실제로 그런 상태였음.
"""

from datetime import date, datetime


def _to_date_string(value) -> str | None:
    if value is None:
        return None
    if isinstance(value, (date, datetime)):
        return value.strftime("%Y-%m-%d")
    return str(value)


# 라인업 미공개 포스터에서 모델이 진짜 null 대신 문자열로 뱉는 경우.
# 이대로 두면 "null"이라는 이름의 가짜 아티스트가 DB artist_name에 박힘
_NULL_LITERALS = {"null", "none", "n/a", "na", "unknown", "미상"}


def _is_null_literal(name: str) -> bool:
    return name.strip().lower() in _NULL_LITERALS


# lineup(우선) 또는 timetable에서 실제로 이름이 채워진 항목만 뽑아 중복 제거한 리스트로
# 반환. 블라인드 라인업(artist=None)은 자연히 걸러짐 - 순서는 처음 등장한 순서 유지
def _extract_artist_names(raw: dict) -> list[str]:
    entries = raw.get("lineup") or raw.get("timetable") or []
    seen: set[str] = set()
    names: list[str] = []
    for entry in entries:
        name = entry.get("artist")
        if name and not _is_null_literal(name) and name not in seen:
            seen.add(name)
            names.append(name)
    return names


# LLM 네이티브 타임테이블 항목({performance_date,time,artist,stage})을 백엔드
# TimeTableEntry({date,time,stage,event})로 변환. event는 필수(non-null) 필드라
# artist가 없는 블라인드 항목은 안내 문구로 채워야 검증을 통과함
def _to_timetable_entry(entry: dict) -> dict:
    artist = entry.get("artist")
    time_ = entry.get("time")
    if artist and time_:
        event = f"{artist} {time_}"
    elif artist:
        event = artist
    else:
        event = "라인업 미공개"
    return {
        "date": entry.get("performance_date"),
        "time": time_,
        "stage": entry.get("stage"),
        "event": event,
    }


# lineup에서 아티스트명+출연일이 둘 다 채워진 항목만 뽑아 백엔드 concert_lineups 웹훅
# 페이로드로 만든다. 날짜를 모르는 항목(performance_date=null)은 여기서 버림 - 백엔드
# 테이블은 "날짜가 있는 배정"만 저장하고, 날짜 모르는 아티스트는 저장 안 해도 항상 폴백(전체
# 표시)되니 보낼 필요가 없음. 같은 (artist,date) 조합 중복도 제거. crawl/artist 두 경로가
# 공유(analyze_crawl_screenshot/extract_artists_from_poster 둘 다 lineup을 이 형태로 반환).
def normalize_lineup_entries(raw) -> list[dict]:
    if not isinstance(raw, dict):
        return []
    entries = raw.get("lineup") or []
    seen: set[tuple[str, str]] = set()
    result: list[dict] = []
    for entry in entries:
        name = entry.get("artist")
        perf_date = entry.get("performance_date")
        if not name or _is_null_literal(name) or not perf_date:
            continue
        key = (name, perf_date)
        if key in seen:
            continue
        seen.add(key)
        result.append({"artist": name, "performance_date": perf_date})
    return result


def normalize_crawl_result(raw: dict) -> dict:
    body: dict = {}

    if raw.get("timetable") is not None:
        body["timetable"] = [_to_timetable_entry(entry) for entry in raw["timetable"]]

    if raw.get("ticket_prices") is not None:
        body["prices"] = raw["ticket_prices"]  # seat_type/price 키가 백엔드와 동일해 그대로 통과

    # venue_layout은 안 쓰기로 결정해 매핑 없음 (POSTER_INFO_SCHEMA에도 없는 키)

    # 크롤링 "완료" 판정에 쓰이는 필드(crawler.py) - 없으면 계속 재크롤링 대상으로 남음
    if raw.get("ticketing_date") is not None:
        body["ticketing_date"] = _to_date_string(raw["ticketing_date"])

    if raw.get("ticket_delivery_date") is not None:
        body["delivery_date"] = _to_date_string(raw["ticket_delivery_date"])

    artist_names = _extract_artist_names(raw)
    if artist_names:
        body["artist_name"] = artist_names

    lineup = normalize_lineup_entries(raw)
    if lineup:
        body["lineup"] = lineup

    food_allowed = (raw.get("other_info") or {}).get("food_allowed")
    if food_allowed is not None:
        body["food_allowed"] = food_allowed

    return body


# extract_artists_from_poster가 analyze_crawl_screenshot과 같은 추론 함수를 재사용하므로
# (포스터든 크롤링 스크린샷이든 같은 전체 스키마를 반환), raw가 dict면 그 안에서 아티스트명만
# 뽑아낸다. 혹시 나중에 단순 리스트를 반환하도록 바뀌어도 그대로 동작하게 이중으로 처리
def normalize_artist_list(raw) -> list[str]:
    if raw is None:
        return []
    if isinstance(raw, dict):
        return _extract_artist_names(raw)
    return [str(name) for name in raw]


# extract_poster.py 결과에는 이 키가 없으므로 자연히 None이 된다. 백엔드 ArtistExtractionResult
# 스키마와 값이 정확히 같아야 그대로 실어보낼 수 있어서, 셋 중 하나가 아니면 신호 없음(None)으로 취급
_VALID_EVENT_TYPES = {"SOLO", "FESTIVAL", "UNKNOWN"}


def normalize_event_type(raw) -> str | None:
    if not isinstance(raw, dict):
        return None
    value = raw.get("event_type")
    return value if value in _VALID_EVENT_TYPES else None


def normalize_diary_text(raw) -> str:
    return str(raw) if raw is not None else ""
