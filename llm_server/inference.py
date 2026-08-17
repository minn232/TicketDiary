"""
LLM팀이 채울 부분은 이 파일뿐입니다. 라우팅/인증/ACK/백그라운드 처리/콜백 전송/중복
방지는 이미 전부 구현되어 있어서 신경 쓸 필요 없습니다.

analyze_crawl_screenshot/extract_artists_from_poster는 LLM팀 실제 코드(extract_poster.py,
파일명 그대로 옮겨옴)의 extract_poster_info()를 공유해서 씁니다 - 크롤링 스크린샷이든
포스터든 같은 이미지 분석 모델을 쓰기 때문입니다. 반환값은 poster_info 스키마(schema.py의
POSTER_INFO_SCHEMA) 전체 dict 그대로이고, 백엔드가 기대하는 필드명으로 바꾸는 것/아티스트명만
뽑아내는 것은 normalize.py가 담당합니다(이 파일은 손댈 필요 없음).
"""

from config import settings
from extract_poster import extract_poster_info
from schemas import ArtistExtractItem, CrawlAnalyzeItem, DiaryGenerateItem


def analyze_crawl_screenshot(item: CrawlAnalyzeItem) -> dict:
    """예매 사이트 크롤링 스크린샷(item.screenshot_url)에서 타임테이블/가격/배송일/
    아티스트명/음식물 반입 여부를 뽑아낸다 (poster_info 스키마 그대로 반환)."""
    return extract_poster_info(item.screenshot_url, base_url=settings.VLLM_BASE_URL, api_key=settings.VLLM_API_KEY)


def extract_artists_from_poster(item: ArtistExtractItem) -> dict:
    """공연 포스터(item.poster_url)에서 정보를 뽑아낸다. analyze_crawl_screenshot과 같은
    함수를 재사용하므로 반환값도 동일한 poster_info 스키마 dict - normalize.py가 그 안에서
    아티스트명만 뽑아 쓴다."""
    return extract_poster_info(item.poster_url, base_url=settings.VLLM_BASE_URL, api_key=settings.VLLM_API_KEY)


def generate_diary_text(item: DiaryGenerateItem) -> str:
    """
    유저 한줄평(item.review)과 공연 정보(item.concert_name/artist_name/venue/concert_date)를
    바탕으로 공연 일기 텍스트를 생성한다.
    """
    raise NotImplementedError("TODO: LLM팀 - 공연 일기 생성 로직 구현")
