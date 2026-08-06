import asyncio
import hashlib
import logging
import re
from datetime import datetime, timedelta, timezone
from urllib.parse import quote
from uuid import UUID

import httpx
from playwright.async_api import async_playwright
from playwright_stealth import Stealth
from sqlalchemy import select, update

from app.core.config import settings
from app.core.database import AsyncSessionLocal
from app.models.concert import Concert, EventType
from app.models.social import ConcertFollow
from app.services.kopis import refresh_ticketing_links
from app.services.site_aliases import normalize_site_key
from app.services.storage import _do_upload

logger = logging.getLogger(__name__)

_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/131.0.0.0 Safari/537.36"
)


_EXTRA_HEADERS = {
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
    "Accept-Language": "ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7",
    "Accept-Encoding": "gzip, deflate, br",
}


_STEALTH = Stealth(
    navigator_languages_override=("ko-KR", "ko"),
    navigator_user_agent_override=_UA,
)


# Playwright 브라우저 + 페이지 생성 (playwright-stealth로 봇 감지 우회)
# context/stealth/new_page 단계에서 실패하면 이미 launch된 browser를 여기서 직접 닫아야 함
# (호출부의 try/finally는 이 함수가 정상 반환된 뒤에야 browser를 참조할 수 있어서, 반환 전에
# 예외가 나면 그 finally가 걸리지 못해 브라우저 프로세스가 누수됨)
async def _make_page(pw):
    browser = await pw.chromium.launch(
        headless=True,
        args=["--disable-blink-features=AutomationControlled"],
    )
    try:
        context = await browser.new_context(
            user_agent=_UA,
            viewport={"width": 1280, "height": 900},
            extra_http_headers=_EXTRA_HEADERS,
        )
        await _STEALTH.apply_stealth_async(context)
        page = await context.new_page()
    except Exception:
        await browser.close()
        raise
    return browser, page


# 아직 정보가 없거나(티켓팅 오픈 전) 상품이 없는 페이지 감지용 키워드.
# ticketing_links의 direct_url로 바로 들어갔을 때, KOPIS엔 이미 등록됐지만 해당 사이트에
# 아직 실제 판매 페이지가 없는 경우("오픈 예정" 안내만 있거나 검색결과가 비어있음)를 걸러내기 위함
# - 사이트마다 실제 문구가 다르고 바뀔 수 있어 완벽하지 않음, 실제 크롤링 결과 보면서 조정 필요
_UNAVAILABLE_PAGE_KEYWORDS = [
    "검색결과가 없습니다",
    "검색 결과가 없습니다",
    "상품이 존재하지 않습니다",
    "판매중인 상품이 없습니다",
    "요청하신 페이지를 찾을 수 없습니다",
    "페이지를 찾을 수 없습니다",
    "오픈 예정",
    # "오픈예정"(공백 없음)은 넣지 않음 - 인터파크 상단 내비게이션의 카테고리 링크로 모든
    # 페이지에 항상 존재해서(실측 확인, 2026-07-29), 실제 공연 정보가 정상적으로 있는
    # 페이지도 전부 "오픈 전"으로 오판시키는 false positive였음
    "준비중입니다",
    "준비 중입니다",
    "등록된 공연이 없습니다",
]


# 현재 페이지가 "아직 정보 없음/오픈 전" 상태로 보이는지 본문 텍스트로 추정 (실패해도 예외 없이 False)
async def _is_unavailable_page(page) -> bool:
    try:
        text = await page.inner_text("body")
    except Exception:
        return False
    return any(keyword in text for keyword in _UNAVAILABLE_PAGE_KEYWORDS)


# NOL(야놀자, nol.yanolja.com) 상세 페이지의 "상품 상세"/"공지사항" 섹션은 기본적으로 접혀있고
# 각각 "상품 상세 더보기"/"공지사항 더보기" 버튼을 직접 눌러야 전체 내용(라인업 포스터 이미지,
# 공지 전문)이 펼쳐짐(실측 확인, 2026-08-05 - nol.yanolja.com/ticket/products/26010721). 안
# 누르면 전체 페이지 스크린샷에서 뒷부분이 잘려서 나온다. 둘 다 순수 인라인 확장이라(모달·페이지
# 이동 없음, 실측으로 role=dialog 없음/body overflow 안 바뀜 확인) 같은 방식으로 처리 가능.
# "가격 전체보기"는 이 둘과 달리 모달 팝업이라(role=dialog, 배경 스크롤 잠김) 같은 전체 페이지
# 스크린샷에 끼워 넣으면 배경을 덮어 오히려 다른 내용을 가리므로 여기서는 다루지 않음 - 별도 캡처가
# 필요한 기능이라 스코프 밖으로 둔다(가격이 날짜별로 다른 경우에만 의미 있고, 대표가는 보통 본문에
# 이미 나와 있음).
#
# 인터파크의 "NOL 티켓"이 2026-09-08부로 서비스를 종료하고 이 nol.yanolja.com으로 예매가
# 이관되는 중이라(해당 페이지 공지사항에서 확인), ticketing_links의 INTERPARK 키에 이 도메인
# URL이 들어오기 시작함 - 그래서 별도 크롤러를 새로 만들지 않고 crawl_interpark 안에서 같이
# 처리한다. 구 인터파크 페이지엔 이 버튼들 자체가 없어 count()==0으로 조용히 넘어감
_SHOW_MORE_BUTTON_TEXTS = ("상품 상세 더보기", "공지사항 더보기")


async def _expand_collapsed_sections(page) -> None:
    clicked = False
    for text in _SHOW_MORE_BUTTON_TEXTS:
        try:
            show_more = page.locator(f'button:has-text("{text}")')
            if await show_more.count() > 0:
                await show_more.click()
                await page.wait_for_timeout(500)
                clicked = True
        except Exception as e:
            logger.warning(f"'{text}' 버튼 클릭 실패 (무시하고 계속): {e}")

    if clicked:
        # 버튼 클릭 시 Playwright가 요소를 뷰포트 안으로 자동 스크롤시키는데, 그 상태로 바로
        # full_page 스크린샷을 찍으면 position:fixed인 상단 헤더가 원래 위치(맨 위)가 아니라
        # 스크롤된 지점에 고정된 채로 캡처되어 본문 이미지 중간에 겹쳐 나옴(실측 확인, 2026-08-05
        # - 헤더가 "더보기" 버튼이 있던 자리에 그대로 끼어들어옴). 스크린샷 직전에 항상 맨 위로
        # 스크롤을 되돌려 이 문제를 방지한다
        try:
            await page.evaluate("window.scrollTo(0, 0)")
            await page.wait_for_timeout(200)
        except Exception as e:
            logger.warning(f"스크롤 리셋 실패 (무시하고 계속): {e}")


# 라인업 변경 감지에서 조회수/좋아요수 등 실시간으로 계속 바뀌는 숫자 노이즈를 없애기 위한 정규화.
# 완벽하진 않음(날짜처럼 진짜 의미있는 숫자도 같이 지워짐) - 라인업 변경 판단 목적으론 괜찮은 트레이드오프
_DIGIT_RE = re.compile(r"\d+")

# 인터파크 상세 페이지의 "캐스팅" 섹션 바로 아래에 붙는 "{아티스트명} 더 알아보기" 한 줄이
# 방문할 때마다 라인업 중 무작위 한 명으로 로테이션되는 걸 실측으로 확인함(2026-07-29,
# scripts/test_lineup_diff.py로 goods/26009383을 8초 간격 두 번 방문 - 실제 라인업 목록
# 자체는 완전히 동일했는데 이 줄 하나 때문에 해시가 달라짐). 숫자가 아닌 노이즈라 위 digit
# 제거만으론 못 잡아서 별도로 걸러냄
_LEARN_MORE_LINE_RE = re.compile(r"^.*더\s*알아보기.*$", re.MULTILINE)


def _hash_lineup_text(text: str) -> str:
    text = _LEARN_MORE_LINE_RE.sub("", text)
    return hashlib.sha256(_DIGIT_RE.sub("", text).encode()).hexdigest()


# 광고/추천 캐러셀에 흔히 쓰이는 이미지 CDN 키워드 - 라인업과 무관한 노이즈라 비교 대상에서 제외.
# 1차 버전이라 대략적인 키워드 목록만 두고, 실제 오탐 데이터가 쌓이면 사이트별로 더 좁힐 것
_AD_IMG_KEYWORDS = ("doubleclick", "googlesyndication", "criteo", "banner", "recommend", "/ad/", "ad.")


# 이미지 src 목록에서 광고 추정 URL을 제외하고, 캐시버스팅 쿼리스트링을 제거한 뒤 정렬된 목록으로 반환
def _normalize_lineup_img_srcs(srcs: list[str]) -> list[str]:
    normalized = set()
    for src in srcs:
        if not src:
            continue
        lowered = src.lower()
        if any(keyword in lowered for keyword in _AD_IMG_KEYWORDS):
            continue
        normalized.add(src.split("?", 1)[0])
    return sorted(normalized)


# 라인업 변경 감지용 스냅샷(원본 텍스트 + 해시 + 이미지 경로 목록) 캡처. 스크린샷과 같은 페이지
# 방문에서 함께 뽑아야 브라우저를 두 번 띄우지 않아도 됨. 원본 텍스트는 실제 배치 로직(정규화된
# 해시만 비교)에선 안 쓰이지만, scripts/test_lineup_diff.py에서 광고/카운터 노이즈를 눈으로
# 직접 비교해볼 수 있게 그대로 반환해둠
async def _capture_lineup_snapshot(page) -> tuple[str, str, list[str]]:
    text = await page.inner_text("body")
    img_srcs = await page.eval_on_selector_all("img", "els => els.map(e => e.src)")
    return text, _hash_lineup_text(text), _normalize_lineup_img_srcs(img_srcs)


# 스크린샷 S3 업로드 후 URL 반환 (실패 시 None)
async def _upload_screenshot(image_bytes: bytes, concert_id, site: str) -> str | None:
    key = f"crawls/{concert_id}/{site}.png"
    loop = asyncio.get_running_loop()
    try:
        return await loop.run_in_executor(None, _do_upload, image_bytes, key, "image/png")
    except Exception as e:
        logger.error(f"스크린샷 업로드 실패 ({site}): {e}")
        return None


# 인터파크 공연 검색 → 상세 페이지 전체 스크린샷
# capture_lineup_snapshot=True면 (screenshot, text, text_hash, img_srcs) 튜플을 반환 (라인업 재크롤링 배치용)
async def crawl_interpark(
    concert: Concert, direct_url: str | None = None, capture_lineup_snapshot: bool = False
) -> bytes | tuple[bytes, str, str, list[str]] | None:
    try:
        async with async_playwright() as pw:
            browser, page = await _make_page(pw)
            try:
                if direct_url:
                    await page.goto(direct_url, wait_until="domcontentloaded", timeout=30_000)
                    await page.wait_for_timeout(2_000)
                    if await _is_unavailable_page(page):
                        logger.info(f"인터파크 아직 정보 없음/오픈 전으로 추정: {concert.name}")
                        return None
                    await _expand_collapsed_sections(page)
                    screenshot = await page.screenshot(full_page=True, type="png")
                    if capture_lineup_snapshot:
                        text, text_hash, img_srcs = await _capture_lineup_snapshot(page)
                        return screenshot, text, text_hash, img_srcs
                    return screenshot

                keyword = quote(concert.name)
                # 기본 /search 경로는 "판매중/판매예정"만 검색해 이미 끝난 공연은 결과가 0건이 되므로
                # status에 CLOSED를 명시해 판매종료 공연도 검색되게 함
                search_url = (
                    f"https://tickets.interpark.com/contents/search?keyword={keyword}"
                    f"&status=OPENED&status=CLOSED&status=SCHEDULED"
                )
                await page.goto(search_url, wait_until="domcontentloaded", timeout=30_000)
                await page.wait_for_timeout(2_000)

                # 검색 결과 카드는 <a>에 href가 없고 JS 클릭 핸들러로만 라우팅되며 새 탭(target=_blank)으로 열림
                # (실제 사이트 DOM 확인 결과, role="link"인데 href 속성 자체가 없어 get_attribute로는 못 읽음)
                result_card = page.locator('a[class*="TicketItem_ticketItem"]').first
                if await result_card.count() == 0:
                    # 검색 결과가 0건("검색결과가 없습니다")인 경우 - 빈 검색결과 페이지를 성공으로
                    # 오인해 스크린샷하지 않도록 실패로 처리
                    logger.info(f"인터파크 검색 결과 없음: {concert.name}")
                    return None

                async with page.context.expect_page(timeout=10_000) as new_page_info:
                    await result_card.click()
                detail_page = await new_page_info.value
                await detail_page.wait_for_load_state("domcontentloaded")
                await detail_page.wait_for_timeout(2_000)
                await _expand_collapsed_sections(detail_page)
                screenshot = await detail_page.screenshot(full_page=True, type="png")
                if capture_lineup_snapshot:
                    text, text_hash, img_srcs = await _capture_lineup_snapshot(detail_page)
                    return screenshot, text, text_hash, img_srcs
                return screenshot
            finally:
                await browser.close()
    except Exception as e:
        logger.warning(f"인터파크 크롤링 실패 ({concert.name}): {e}")
        return None


# YES24 공연 검색 → 상세 페이지 전체 스크린샷
# capture_lineup_snapshot=True면 (screenshot, text, text_hash, img_srcs) 튜플을 반환 (라인업 재크롤링 배치용)
async def crawl_yes24(
    concert: Concert, direct_url: str | None = None, capture_lineup_snapshot: bool = False
) -> bytes | tuple[bytes, str, str, list[str]] | None:
    try:
        async with async_playwright() as pw:
            browser, page = await _make_page(pw)
            try:
                if direct_url:
                    await page.goto(direct_url, wait_until="domcontentloaded", timeout=30_000)
                    await page.wait_for_timeout(2_000)
                    if await _is_unavailable_page(page):
                        logger.info(f"YES24 아직 정보 없음/오픈 전으로 추정: {concert.name}")
                        return None
                else:
                    keyword = quote(concert.name)
                    search_url = f"https://ticket.yes24.com/New/Search/Search.aspx?q={keyword}"
                    await page.goto(search_url, wait_until="domcontentloaded", timeout=30_000)
                    await page.wait_for_timeout(2_000)

                    href = await page.get_attribute('a[href*="/New/Perf/"]', "href")
                    if href:
                        if not href.startswith("http"):
                            href = f"https://ticket.yes24.com{href}"
                        await page.goto(href, wait_until="domcontentloaded", timeout=30_000)
                        await page.wait_for_timeout(2_000)

                screenshot = await page.screenshot(full_page=True, type="png")
                if capture_lineup_snapshot:
                    text, text_hash, img_srcs = await _capture_lineup_snapshot(page)
                    return screenshot, text, text_hash, img_srcs
                return screenshot
            finally:
                await browser.close()
    except Exception as e:
        logger.warning(f"YES24 크롤링 실패 ({concert.name}): {e}")
        return None


# 멜론티켓 공연 검색 → 상세 페이지 전체 스크린샷 (봇 차단 시 graceful skip)
# capture_lineup_snapshot=True면 (screenshot, text, text_hash, img_srcs) 튜플을 반환 (라인업 재크롤링 배치용)
async def crawl_melon(
    concert: Concert, direct_url: str | None = None, capture_lineup_snapshot: bool = False
) -> bytes | tuple[bytes, str, str, list[str]] | None:
    try:
        async with async_playwright() as pw:
            browser, page = await _make_page(pw)
            try:
                if direct_url:
                    await page.goto(direct_url, wait_until="domcontentloaded", timeout=30_000)
                    await page.wait_for_timeout(2_000)
                    if "accounts.kakao.com" in page.url or "auth.kakao.com" in page.url:
                        logger.info(f"멜론티켓 봇 차단 감지 (Kakao 리다이렉트): {concert.name}")
                        return None
                    if await _is_unavailable_page(page):
                        logger.info(f"멜론티켓 아직 정보 없음/오픈 전으로 추정: {concert.name}")
                        return None
                else:
                    keyword = quote(concert.name)
                    search_url = f"https://ticket.melon.com/search/index.htm?q={keyword}"
                    await page.goto(search_url, wait_until="domcontentloaded", timeout=30_000)
                    await page.wait_for_timeout(2_000)

                    if "accounts.kakao.com" in page.url or "auth.kakao.com" in page.url:
                        logger.info(f"멜론티켓 봇 차단 감지 (Kakao 리다이렉트): {concert.name}")
                        return None

                    href = await page.get_attribute('a[href*="/performance/"]', "href")
                    if href:
                        if not href.startswith("http"):
                            href = f"https://ticket.melon.com{href}"
                        await page.goto(href, wait_until="domcontentloaded", timeout=30_000)
                        await page.wait_for_timeout(2_000)

                        if "accounts.kakao.com" in page.url or "auth.kakao.com" in page.url:
                            logger.info(f"멜론티켓 봇 차단 감지 (상세 페이지): {concert.name}")
                            return None

                screenshot = await page.screenshot(full_page=True, type="png")
                if capture_lineup_snapshot:
                    text, text_hash, img_srcs = await _capture_lineup_snapshot(page)
                    return screenshot, text, text_hash, img_srcs
                return screenshot
            finally:
                await browser.close()
    except Exception as e:
        logger.warning(f"멜론티켓 크롤링 실패 ({concert.name}): {e}")
        return None


# KOPIS 공연 상세 페이지 전체 스크린샷 (티켓링크 폴백용)
async def crawl_kopis(concert: Concert) -> bytes | None:
    if not concert.kopis_id:
        logger.info(f"KOPIS ID 없음 — 크롤링 불가: {concert.name}")
        return None

    url = (
        f"https://kopis.or.kr/por/db/pblprfr/pblprfrView.do"
        f"?menuId=MNU_00099&mt20Id={concert.kopis_id}"
    )
    try:
        async with async_playwright() as pw:
            browser, page = await _make_page(pw)
            try:
                await page.goto(url, wait_until="networkidle", timeout=30_000)
                return await page.screenshot(full_page=True, type="png")
            finally:
                await browser.close()
    except Exception as e:
        logger.warning(f"KOPIS 크롤링 실패 ({concert.name}): {e}")
        return None


# 임의 URL을 직접 받아 전체 페이지 스크린샷 반환
# 홈 먼저 방문해 쿠키/세션을 세팅한 뒤 목표 URL로 이동 (500 오류 방지)
# verbose=True 시 최종 URL·타이틀을 로그로 출력
async def crawl_url(url: str, wait_ms: int = 2000, verbose: bool = False) -> bytes | None:
    try:
        async with async_playwright() as pw:
            browser, page = await _make_page(pw)
            try:
                await page.goto(url, wait_until="domcontentloaded", timeout=30_000)
                await page.wait_for_timeout(wait_ms)
                if verbose:
                    title = await page.title()
                    logger.info(f"[최종 URL] {page.url}")
                    logger.info(f"[페이지 제목] {title}")
                return await page.screenshot(full_page=True, type="png")
            finally:
                await browser.close()
    except Exception as e:
        logger.warning(f"URL 크롤링 실패 ({url}): {e}")
        return None


# 지원 사이트 → 크롤링 함수 매핑 (대소문자 정규화 후 조회)
_CRAWLERS: dict[str, callable] = {
    "INTERPARK": crawl_interpark,
    "인터파크": crawl_interpark,
    "YES24": crawl_yes24,
    "MELON": crawl_melon,
    "MELONTICKET": crawl_melon,
    "멜론티켓": crawl_melon,
    "멜론": crawl_melon,
}

# 크롤링 지원 사이트 우선순위 (YES24 > INTERPARK > MELON)
_PREFERRED_SITES = ["YES24", "INTERPARK", "MELON"]

# 크롤링 미지원 사이트
_UNSUPPORTED_SITES = {"TICKETLINK", "티켓링크"}


# 크롤링할 사이트와 직접 URL을 결정 (ticketing_links에 지원 사이트가 있으면 YES24 > INTERPARK > MELON
# 순 우선 선택, 없으면 ticketing_site가 지원 사이트인 경우에만 이름 검색 방식으로 진행,
# 티켓링크만 있거나 ticketing_site가 티켓링크면 (None, None) 반환)
# ticketing_site는 찜(follow) 트리거처럼 유저가 아직 티켓을 등록하지 않은 경우 None일 수 있음
def _pick_crawl_target(
    ticketing_site: str | None, ticketing_links: dict[str, str] | None
) -> tuple[str | None, str | None]:
    links = ticketing_links or {}
    for site in _PREFERRED_SITES:
        if site in links:
            return site, links[site]
    if not ticketing_site:
        return None, None
    site_key = normalize_site_key(ticketing_site)
    if site_key in _UNSUPPORTED_SITES:
        return None, None
    return site_key, links.get(site_key)


# 알려진 사이트 키 집합 (대소문자 정규화 후 조회용)
_KNOWN_SITE_KEYS: frozenset[str] = frozenset(
    {k.upper() for k in _CRAWLERS} | {s.upper() for s in _UNSUPPORTED_SITES}
)


# 크롤링 재시도 간 최소 간격. ticketing_date를 아직 못 얻은 공연은 "완료"로 보지 않고 계속
# 재시도 대상이 되므로, 찜/티켓등록이 반복될 때마다 매번 크롤링하지 않도록 쿨다운을 둠
_CRAWL_RETRY_COOLDOWN = timedelta(hours=24)

# 재시도를 포기하는 최대 누적 시도 횟수 (쿨다운 24h 기준 최대 한 달 정도). 검색 자체가 계속
# 실패하는 등 구조적으로 안 되는 공연에 축제처럼 긴 상영 기간 내내 매일 재시도하며 리소스를
# 낭비하지 않기 위한 상한. 찜/티켓등록으로 즉시 재트리거되는 경우도 이 카운트에 포함됨
_MAX_CRAWL_ATTEMPTS = 30


# 티켓 등록 또는 공연 찜(follow) 시 백그라운드 태스크로 호출: 크롤링 후 Concert.crawl_screenshot_url 갱신
# ticketing_site는 티켓 등록 경로에서만 값이 있고, 찜 경로에서는 아직 아무도 티켓을 안 샀을 수 있어
# None으로 넘어옴 - 이 경우 concert.ticketing_links(KOPIS 상세조회로 이미 채워져 있음)만으로 크롤링을
# 시도하므로, ticketing_site 유효성 검사를 DB 조회(및 ticketing_links 확인)보다 먼저 하지 않는다
#
# "크롤링 완료"는 스크린샷 존재 여부가 아니라 ticketing_date를 실제로 얻었는지로 판단한다.
# KOPIS는 티켓팅 오픈 전에도 공연을 먼저 등록하는 경우가 흔해서, 그 시점에 예매 사이트 페이지를
# 크롤링하면 "오픈 예정" 같은 빈 페이지만 찍힐 수 있는데, 예전엔 스크린샷이 한 번이라도 찍히면
# 영구히 재크롤링을 안 해서 나중에 진짜 정보가 채워져도 절대 못 얻어오는 문제가 있었음
async def crawl_and_save(concert_id, ticketing_site: str | None = None) -> None:
    if ticketing_site and normalize_site_key(ticketing_site) not in _KNOWN_SITE_KEYS:
        logger.info(f"크롤링 미지원 사이트: {ticketing_site}")
        ticketing_site = None

    async with AsyncSessionLocal() as db:
        # 티켓등록/찜/야간배치 세 경로가 동시에 같은 공연을 크롤링 시도할 수 있어 row lock으로 직렬화.
        # 먼저 들어온 트랜잭션이 crawl_attempted_at을 갱신하고 커밋(=잠금 해제)하면, 대기하던
        # 트랜잭션은 그 갱신된 값을 보고 쿨다운에 걸려 정상적으로 중복 크롤링을 건너뜀
        result = await db.execute(
            select(Concert).where(Concert.id == concert_id).with_for_update()
        )
        concert = result.scalar_one_or_none()
        if concert is None:
            return

        now = datetime.now(timezone.utc)

        # 이미 필요한 정보(티켓팅 오픈일)를 얻었으면 더 크롤링할 필요 없음
        if concert.ticketing_date is not None:
            return

        # 공연이 이미 끝났으면 더 이상 의미 없음
        if concert.end_date is not None and concert.end_date <= now:
            return

        # 최근에 이미 시도했으면(성공/실패 무관) 너무 자주 재시도하지 않도록 쿨다운
        if concert.crawl_attempted_at is not None and now - concert.crawl_attempted_at < _CRAWL_RETRY_COOLDOWN:
            return

        if concert.crawl_attempt_count >= _MAX_CRAWL_ATTEMPTS:
            logger.info(f"크롤링 재시도 횟수 초과, 포기: {concert.name} ({concert.crawl_attempt_count}회)")
            return

        if not ticketing_site and not concert.ticketing_links:
            logger.info(f"크롤링 대상 사이트 정보 없음, 스킵: {concert.name}")
            return

        concert.crawl_attempted_at = now
        concert.crawl_attempt_count += 1
        await db.commit()

        site_key, direct_url = _pick_crawl_target(ticketing_site, concert.ticketing_links)
        if site_key is None:
            # 티켓링크 전용 공연 → KOPIS 페이지로 폴백
            logger.info(f"티켓링크 미지원 → KOPIS 폴백: {concert.name}")
            image_bytes = await crawl_kopis(concert)
            upload_key = "kopis"
        else:
            crawler = _CRAWLERS.get(site_key)
            if crawler is None:
                logger.info(f"크롤링 미지원 사이트: {site_key}")
                return

            logger.info(f"크롤링 대상: {site_key} (직접 URL: {bool(direct_url)})")
            image_bytes = await crawler(concert, direct_url=direct_url)
            upload_key = site_key.lower()

        if image_bytes is None:
            return

        url = await _upload_screenshot(image_bytes, concert_id, upload_key)
        if url:
            concert.crawl_screenshot_url = url
            await db.commit()
            logger.info(f"크롤링 완료: {concert.name} → {url}")


# 자정 배치: 예정된 공연 스크린샷 LLM팀 웹훅으로 전송
async def send_screenshots_to_llm() -> None:
    if not settings.LLM_CRAWL_URL:
        logger.info("LLM_CRAWL_URL 미설정, 전송 건너뜀")
        return

    now = datetime.now(timezone.utc)

    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(Concert).where(
                Concert.crawl_screenshot_url.isnot(None),
                Concert.end_date > now,
            )
        )
        concerts = list(result.scalars().all())

    if not concerts:
        logger.info("전송할 크롤링 스크린샷 없음")
        return

    payload = [
        {
            "concert_id": str(c.id),
            "concert_name": c.name,
            "screenshot_url": c.crawl_screenshot_url,
        }
        for c in concerts
    ]

    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(
                settings.LLM_CRAWL_URL,
                json=payload,
                headers={"Authorization": f"Bearer {settings.LLM_EXTRACT_API_KEY}"},
            )
            response.raise_for_status()
        logger.info(f"LLM팀 스크린샷 전송 완료: {len(concerts)}건")
    except Exception as e:
        logger.error(f"LLM팀 스크린샷 전송 실패: {e}")


# 자정 배치: 아티스트 정보 없는 공연의 포스터를 VLM팀에 보내 아티스트 추출 요청
# (포스터 내용은 시간이 지나도 안 바뀌므로 크롤링과 달리 쿨다운/재시도 없이 한 번만 시도함 -
# 전송 자체가 실패하면 artist_extraction_attempted_at을 안 남겨서 다음 배치에서 다시 시도됨)
async def send_posters_for_artist_extraction() -> None:
    if not settings.LLM_ARTIST_URL:
        logger.info("LLM_ARTIST_URL 미설정, 전송 건너뜀")
        return

    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(Concert).where(
                Concert.artist_name == [],
                Concert.poster_url.isnot(None),
                Concert.artist_extraction_attempted_at.is_(None),
            )
        )
        concerts = list(result.scalars().all())

    if not concerts:
        logger.info("아티스트 추출 대상 공연 없음")
        return

    payload = [
        {"concert_id": str(c.id), "concert_name": c.name, "poster_url": c.poster_url}
        for c in concerts
    ]

    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(
                settings.LLM_ARTIST_URL,
                json=payload,
                headers={"Authorization": f"Bearer {settings.LLM_EXTRACT_API_KEY}"},
            )
            response.raise_for_status()
    except Exception as e:
        logger.error(f"LLM팀 포스터 전송 실패: {e}")
        return

    now = datetime.now(timezone.utc)
    concert_ids = [c.id for c in concerts]
    async with AsyncSessionLocal() as db:
        await db.execute(
            update(Concert).where(Concert.id.in_(concert_ids)).values(artist_extraction_attempted_at=now)
        )
        await db.commit()

    logger.info(f"LLM팀 포스터 전송 완료: {len(concerts)}건")


# 재시도 배치에서 동시에 띄우는 브라우저 프로세스 수 상한 (무제한 병렬은 메모리/CPU 부담이 큼)
_RETRY_CRAWL_CONCURRENCY = 4


async def _crawl_and_save_limited(semaphore: asyncio.Semaphore, concert_id) -> None:
    async with semaphore:
        await crawl_and_save(concert_id)


# 자정 배치: 찜한 유저가 있는데 아직 ticketing_date를 못 얻은 공연들에 크롤링 재시도
# (crawl_and_save는 follow/티켓등록 시점에도 불리지만, 그 이후로 아무도 다시 찜/등록을 안 하면
# 재시도할 기회 자체가 없으므로 이 배치가 그 역할을 대신함. 쿨다운/완료판단은 crawl_and_save가 함)
async def retry_pending_crawls() -> None:
    async with AsyncSessionLocal() as db:
        follows_result = await db.execute(select(ConcertFollow))
        followed_ids: set[str] = set()
        for follow in follows_result.scalars().all():
            for entry in follow.concerts or []:
                cid = entry.get("concert_id")
                if cid:
                    followed_ids.add(cid)

        if not followed_ids:
            return

        now = datetime.now(timezone.utc)
        result = await db.execute(
            select(Concert.id).where(
                Concert.id.in_([UUID(cid) for cid in followed_ids]),
                Concert.ticketing_date.is_(None),
                Concert.end_date > now,
            )
        )
        concert_ids = [row[0] for row in result.all()]

    if not concert_ids:
        return

    logger.info(f"크롤링 재시도 대상 {len(concert_ids)}건")
    # 브라우저 launch가 건당 수 초 걸려 완전 순차 처리하면 대상이 많을 때 배치가 오래 걸림.
    # kopis.py의 상세조회와 동일하게 세마포어로 동시 실행 개수만 제한해 병렬 처리
    semaphore = asyncio.Semaphore(_RETRY_CRAWL_CONCURRENCY)
    await asyncio.gather(*(_crawl_and_save_limited(semaphore, cid) for cid in concert_ids))


# 페스티벌 라인업 재확인 쿨다운. 진행예정 FESTIVAL이 (2026-07-29 기준 실측) 100여 건 수준이라
# 매일 돌아도 처리 시간 자체는 부담 없음 - 다만 같은 사이트를 매일 반복 방문하는 거라 봇 차단
# 빈도가 늘면 그때 늘리는 식으로 조정할 것
_FESTIVAL_LINEUP_CHECK_COOLDOWN = timedelta(hours=24)


# event_type=FESTIVAL 공연 하나의 라인업이 직전 방문과 달라졌는지 확인하고, 달라졌으면(최초 방문
# 포함) 새 스크린샷을 버전별 키로 업로드해 crawl_screenshot_url을 갱신한다.
# ticketing_date 유무를 안 보는 게 crawl_and_save와의 핵심 차이 - 페스티벌은 1차 라인업 공개 직후
# ticketing_date가 바로 채워지는 경우가 많아, 그 기준으로 완료 판단하면 정작 봐야 할 시점부터
# 재크롤링 대상에서 영영 빠짐
async def _check_festival_lineup(concert_id) -> None:
    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Concert).where(Concert.id == concert_id))
        concert = result.scalar_one_or_none()
        if concert is None:
            return

        now = datetime.now(timezone.utc)

        if concert.end_date is not None and concert.end_date <= now:
            return

        if (
            concert.lineup_check_attempted_at is not None
            and now - concert.lineup_check_attempted_at < _FESTIVAL_LINEUP_CHECK_COOLDOWN
        ):
            return

        # 크롤링 대상을 고르기 전에 먼저 KOPIS 예매링크를 최신화 - 최초 등록 시점(1차 라인업
        # 공개 직후, 얼리버드/블라인드 판매와 겹칠 수 있음)에 캡처된 링크가 이후 실제 판매 링크로
        # 바뀌어도 우리 DB가 영원히 못 따라가는 문제 대응 (자세한 이유는 kopis.py의
        # refresh_ticketing_links 참고). 여기서 갱신된 값이 실패 없이 반영되도록 즉시 커밋한다.
        await refresh_ticketing_links(concert)
        await db.commit()

        # 찜/티켓등록 트리거와 달리 특정 사이트에 안 묶인 주기 배치라 ticketing_site 없이
        # concert.ticketing_links만으로 대상 사이트를 고름 (social.py의 찜 갱신 경로와 동일 패턴)
        site_key, direct_url = _pick_crawl_target(None, concert.ticketing_links)
        if site_key is None:
            return

        crawler = _CRAWLERS.get(site_key)
        if crawler is None:
            return

        # 실제 크롤링 전에 먼저 시각을 찍고 커밋 - crawl_and_save와 동일하게, 크롤링 도중 배치가
        # 죽어도 다음 사이클에 무한정 재시도하지 않도록 함
        concert.lineup_check_attempted_at = now
        await db.commit()

        capture = await crawler(concert, direct_url=direct_url, capture_lineup_snapshot=True)
        if capture is None:
            return

        screenshot, _raw_text, text_hash, img_srcs = capture
        changed = concert.lineup_snapshot_hash is None or text_hash != concert.lineup_snapshot_hash or img_srcs != (
            concert.lineup_snapshot_img_srcs or []
        )
        if not changed:
            return

        # 매번 같은 키를 덮어쓰지 않고 시각을 붙여 버전별로 쌓음 - 1차/2차/3차 라인업 공개 시점의
        # 스크린샷을 나중에 비교/추적할 수 있게, 그리고 llm_server의 dedup이 screenshot_url 단위로
        # 처리 여부를 판단하므로 새 URL이어야 재추출이 실제로 트리거됨
        upload_key = f"{site_key.lower()}_{int(now.timestamp())}"
        url = await _upload_screenshot(screenshot, concert_id, upload_key)
        if url is None:
            return

        concert.crawl_screenshot_url = url
        concert.lineup_snapshot_hash = text_hash
        concert.lineup_snapshot_img_srcs = img_srcs
        await db.commit()
        logger.info(f"페스티벌 라인업 변경 감지, 스크린샷 갱신: {concert.name} → {url}")


async def _check_festival_lineup_limited(semaphore: asyncio.Semaphore, concert_id) -> None:
    async with semaphore:
        await _check_festival_lineup(concert_id)


# 자정 배치: event_type=FESTIVAL로 확정된 진행예정 공연들의 라인업이 직전과 달라졌는지 매일 재확인.
# ticketing_date 유무와 무관하게 계속 대상이 되는 게 retry_pending_crawls와의 차이 (위 설명 참고)
async def retry_festival_lineup_checks() -> None:
    now = datetime.now(timezone.utc)
    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(Concert.id).where(
                Concert.event_type == EventType.FESTIVAL.value,
                Concert.end_date > now,
            )
        )
        concert_ids = [row[0] for row in result.all()]

    if not concert_ids:
        return

    logger.info(f"페스티벌 라인업 재확인 대상 {len(concert_ids)}건")
    semaphore = asyncio.Semaphore(_RETRY_CRAWL_CONCURRENCY)
    await asyncio.gather(*(_check_festival_lineup_limited(semaphore, cid) for cid in concert_ids))
