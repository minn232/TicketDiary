"""
LLM팀이 채울 부분은 이 파일뿐입니다. 아래 세 함수의 내용만 실제 모델 추론 로직으로
채우면 됩니다 - 라우팅/인증/ACK/백그라운드 처리/콜백 전송/중복 방지는 이미 전부
구현되어 있어서 신경 쓸 필요 없습니다.

각 함수는 이미지 URL(들)을 받아서 뽑아낸 정보를 dict/list/str로 반환하면 됩니다.
일부만 뽑아냈으면 나머지 키는 생략(또는 None)해도 됩니다 - 부분 성공을 허용하는
구조라 실패한 항목만 없는 채로 넘어갑니다. 반환 형태가 아래 예시와 완전히 똑같지
않아도 괜찮습니다 (정확한 맞춤은 normalize.py에서 처리).

노트북에서 개발한 추론 코드가 있다면, 그 로직을 그대로 이 함수 본문으로 옮기기만
하면 됩니다.
"""

from schemas import ArtistExtractItem, CrawlAnalyzeItem, DiaryGenerateItem


def analyze_crawl_screenshot(item: CrawlAnalyzeItem) -> dict:
    """
    예매 사이트 크롤링 스크린샷(item.screenshot_url)에서 타임테이블/가격/좌석배치도/
    티켓팅 오픈일/배송 예정일/아티스트명을 뽑아낸다.

    반환 예시 (전부 선택 - 뽑아낸 것만 채워서 반환):
    {
        "timetable": [{"date": "2026-09-19", "time": "18:00", "stage": "MAIN", "event": "..."}],
        "prices": [{"grade": "VIP", "price": 198000}],
        "venue_layout": {"image_url": "https://...", "layout_data": {...}},
        "ticketing_date": "2026-08-01",
        "delivery_date": "2026-09-10",
        "artist_name": ["아티스트1", "아티스트2"],
    }
    """
    raise NotImplementedError("TODO: LLM팀 - 크롤링 스크린샷 분석 로직 구현")


def extract_artists_from_poster(item: ArtistExtractItem) -> list[str]:
    """
    공연 포스터(item.poster_url)에서 출연 아티스트명을 뽑아낸다.
    알아낸 게 없으면 빈 리스트를 반환하면 된다 (에러를 던지지 않아도 됨).
    """
    raise NotImplementedError("TODO: LLM팀 - 포스터 아티스트 추출 로직 구현")


def generate_diary_text(item: DiaryGenerateItem) -> str:
    """
    유저 한줄평(item.review)과 공연 정보(item.concert_name/artist_name/venue/concert_date)를
    바탕으로 공연 일기 텍스트를 생성한다.
    """
    raise NotImplementedError("TODO: LLM팀 - 공연 일기 생성 로직 구현")
