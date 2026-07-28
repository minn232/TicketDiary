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
    delivery_date: str | None = None  # YYYY-MM-DD
    artist_name: list[str] | None = None


class ArtistResultCallback(BaseModel):
    artist_name: list[str]


class DiaryResultCallback(BaseModel):
    diary: str
