import asyncio
import logging
from urllib.parse import quote

import httpx
from playwright.async_api import async_playwright
from playwright_stealth import Stealth
from sqlalchemy import select

from app.core.config import settings
from app.core.database import AsyncSessionLocal
from app.models.concert import Concert
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
async def _make_page(pw):
    browser = await pw.chromium.launch(
        headless=True,
        args=["--disable-blink-features=AutomationControlled"],
    )
    context = await browser.new_context(
        user_agent=_UA,
        viewport={"width": 1280, "height": 900},
        extra_http_headers=_EXTRA_HEADERS,
    )
    await _STEALTH.apply_stealth_async(context)
    page = await context.new_page()
    return browser, page


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
async def crawl_interpark(concert: Concert, direct_url: str | None = None) -> bytes | None:
    try:
        async with async_playwright() as pw:
            browser, page = await _make_page(pw)
            try:
                if direct_url:
                    await page.goto(direct_url, wait_until="domcontentloaded", timeout=30_000)
                    await page.wait_for_timeout(2_000)
                else:
                    keyword = quote(concert.name)
                    search_url = f"https://tickets.interpark.com/search?keyword={keyword}"
                    await page.goto(search_url, wait_until="domcontentloaded", timeout=30_000)
                    await page.wait_for_timeout(2_000)

                    href = await page.get_attribute('a[href*="/goods/"]', "href")
                    if href:
                        if not href.startswith("http"):
                            href = f"https://tickets.interpark.com{href}"
                        await page.goto(href, wait_until="domcontentloaded", timeout=30_000)
                        await page.wait_for_timeout(2_000)

                return await page.screenshot(full_page=True, type="png")
            finally:
                await browser.close()
    except Exception as e:
        logger.warning(f"인터파크 크롤링 실패 ({concert.name}): {e}")
        return None


# YES24 공연 검색 → 상세 페이지 전체 스크린샷
async def crawl_yes24(concert: Concert, direct_url: str | None = None) -> bytes | None:
    try:
        async with async_playwright() as pw:
            browser, page = await _make_page(pw)
            try:
                if direct_url:
                    await page.goto(direct_url, wait_until="domcontentloaded", timeout=30_000)
                    await page.wait_for_timeout(2_000)
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

                return await page.screenshot(full_page=True, type="png")
            finally:
                await browser.close()
    except Exception as e:
        logger.warning(f"YES24 크롤링 실패 ({concert.name}): {e}")
        return None


# 멜론티켓 공연 검색 → 상세 페이지 전체 스크린샷 (봇 차단 시 graceful skip)
async def crawl_melon(concert: Concert, direct_url: str | None = None) -> bytes | None:
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

                return await page.screenshot(full_page=True, type="png")
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


def _pick_crawl_target(
    ticketing_site: str, ticketing_links: dict[str, str] | None
) -> tuple[str | None, str | None]:
    """크롤링할 사이트와 직접 URL을 결정한다.

    ticketing_links에 지원 사이트가 있으면 YES24 > INTERPARK > MELON 순 우선 선택.
    없으면 ticketing_site가 지원 사이트인 경우에만 이름 검색 방식으로 진행.
    ticketlink만 있거나 ticketing_site가 ticketlink면 (None, None) 반환.
    """
    links = ticketing_links or {}
    for site in _PREFERRED_SITES:
        if site in links:
            return site, links[site]
    site_key = ticketing_site.upper()
    if site_key in _UNSUPPORTED_SITES:
        return None, None
    return site_key, links.get(site_key)


# 알려진 사이트 키 집합 (대소문자 정규화 후 조회용)
_KNOWN_SITE_KEYS: frozenset[str] = frozenset(
    {k.upper() for k in _CRAWLERS} | {s.upper() for s in _UNSUPPORTED_SITES}
)


# 티켓 등록 백그라운드 태스크: 크롤링 후 Concert.crawl_screenshot_url 갱신
async def crawl_and_save(concert_id, ticketing_site: str | None) -> None:
    if not ticketing_site:
        return

    if ticketing_site.upper() not in _KNOWN_SITE_KEYS:
        logger.info(f"크롤링 미지원 사이트: {ticketing_site}")
        return

    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Concert).where(Concert.id == concert_id))
        concert = result.scalar_one_or_none()
        if concert is None:
            return

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

    from datetime import datetime, timezone
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
