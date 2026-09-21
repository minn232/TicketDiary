from pydantic import BaseModel


# ── 백엔드 → 이 서버 (인바운드 배치 요청) ──────────────────────────────
# 백엔드가 보내는 요청 바디는 객체로 감싸지 않은 순수 JSON 배열이다
# (예: services/crawler.py의 `client.post(url, json=payload, ...)`에서
# payload가 그대로 list[dict]). 라우트에서 `body: list[CrawlAnalyzeItem]`처럼 받는다.

class CrawlAnalyzeItem(BaseModel):
    concert_id: str
    concert_name: str | None = None
    screenshot_url: str


class ArtistExtractItem(BaseModel):
    concert_id: str
    concert_name: str | None = None
    poster_url: str
    # KOPIS에 등록된 공연장(시설)명 - extract_artist.py 원칙 2번(공연장명 오인 방지)의
    # 근거로 프롬프트에 그대로 실림. 없으면(None) 그 근거 없이 기존처럼 판단함.
    venue: str | None = None


class DiaryGenerateItem(BaseModel):
    ticket_id: str
    review: str | None = None
    concert_name: str | None = None
    artist_name: list[str] = []
    venue: str | None = None
    concert_date: str | None = None  # YYYY-MM-DD


# ── 이 서버 → 백엔드 (콜백 웹훅 바디) ──────────────────────────────
# 백엔드의 CrawlResultRequest/ArtistExtractionResult/DiaryResultRequest와
# 정확히 같은 필드명이어야 함 (backend/app/schemas/venue_layout.py,
# artist_extraction.py, diary.py 참고). 전부 부분 성공 허용 - 뽑아내지
# 못한 필드는 그냥 생략하면 됨(None으로 보내도 무방, 백엔드가 무시함).

class VenueLayoutPayload(BaseModel):
    image_url: str | None = None
    layout_data: dict | None = None


class CrawlResultCallback(BaseModel):
    timetable: list[dict] | None = None  # [{date, time, stage, event}, ...]
    prices: list[dict] | None = None
    venue_layout: VenueLayoutPayload | None = None
    ticketing_date: str | None = None  # YYYY-MM-DD
    ticketing_phases: list[dict] | None = None  # [{"phase": "선예매", "date": "..."|None}, ...]
    delivery_date: str | None = None  # YYYY-MM-DD
    artist_name: list[str] | None = None
    artist_name_ko: list[str | None] | None = None  # artist_name과 같은 길이·순서
    food_allowed: str | None = None  # "가능"/"불가능"/"일부허용"


class ArtistResultCallback(BaseModel):
    artist_name: list[str]
    # 외국 아티스트명을 "한국에서 흔히 부르는" 한글 발음으로 옮긴 표기
    # (예: "Isaiah J. Thompson" -> "아이재아 제이 톰슨"). korean_reading.py가 만든다.
    # artist_name과 길이·순서가 정확히 대응하고, 이미 한글이거나 옮기지 못한 자리는 None -
    # 원문 표기를 대체하는 게 아니라 함께 보여주고 검색에 같이 걸기 위한 부가 필드다.
    # 한글 표기가 하나도 없으면 필드 자체가 빠진다.
    artist_name_ko: list[str | None] | None = None
    # 포스터를 보고 판단한 단독/페스티벌 분류.
    # 백엔드 app/models/concert.py EventType과 값을 정확히 맞출 것("SOLO"/"FESTIVAL"/"UNKNOWN")
    event_type: str | None = None


class DiaryResultCallback(BaseModel):
    diary: str
