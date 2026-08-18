"""
LLM팀이 채울 부분은 이 파일뿐입니다. 라우팅/인증/ACK/백그라운드 처리/콜백 전송/중복
방지는 이미 구현되어 있어 신경 쓸 필요 없습니다.

analyze_crawl_screenshot은 extract_poster.py, extract_artists_from_poster는 아티스트명
전용 프롬프트로 분리한 extract_artist.py를 씁니다(오추출 패턴 4가지 겨냥, 2026-08-18~).
둘 다 반환은 lineup 배열이고 normalize.py가 아티스트명만 뽑아 씀 - 이 파일은 안 건드려도 됩니다.
"""

from config import settings
from extract_artist import extract_artist_info
from extract_poster import extract_poster_info
from schemas import ArtistExtractItem, CrawlAnalyzeItem, DiaryGenerateItem


def analyze_crawl_screenshot(item: CrawlAnalyzeItem) -> dict:
    """예매 사이트 크롤링 스크린샷(item.screenshot_url)에서 타임테이블/가격/배송일/
    아티스트명/음식물 반입 여부를 뽑아낸다 (poster_info 스키마 그대로 반환)."""
    return extract_poster_info(item.screenshot_url, base_url=settings.VLLM_BASE_URL, api_key=settings.VLLM_API_KEY)


def extract_artists_from_poster(item: ArtistExtractItem) -> dict:
    """공연 포스터에서 아티스트명만 뽑는다. concert_name도 같이 넘겨서, 포스터에 이름이
    없고 부제만 있을 때("아티스트명: 부제" 형식) 힌트로 쓸 수 있게 한다."""
    return extract_artist_info(
        item.poster_url, item.concert_name, base_url=settings.VLLM_BASE_URL, api_key=settings.VLLM_API_KEY
    )


def generate_diary_text(item: DiaryGenerateItem) -> str:
    """
    유저 한줄평(item.review)과 공연 정보(item.concert_name/artist_name/venue/concert_date)를
    바탕으로 공연 일기 텍스트를 생성한다.
    """
    raise NotImplementedError("TODO: LLM팀 - 공연 일기 생성 로직 구현")
