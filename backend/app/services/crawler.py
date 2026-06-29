import asyncio
import logging
from urllib.parse import quote

import httpx
from playwright.async_api import async_playwright
from sqlalchemy import select

from app.core.config import settings
from app.core.database import AsyncSessionLocal
from app.models.concert import Concert
from app.services.storage import _do_upload

logger = logging.getLogger(__name__)

_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)


# Playwright 브라우저 + 페이지 생성
async def _make_page(pw):
    browser = await pw.chromium.launch(headless=True)
    context = await browser.new_context(
        user_agent=_UA,
        viewport={"width": 1280, "height": 900},
    )
    page = await context.new_page()
    return browser, page


# 스크린샷 S3 업로드 후 URL 반환 (실패 시 None)
async def _upload_screenshot(image_bytes: bytes, concert_id, site: str) -> str | None:
    key = f"crawls/{concert_id}/{site}.png"
    loop = asyncio.get_event_loop()
    try:
        return await loop.run_in_executor(None, _do_upload, image_bytes, key, "image/png")
    except Exception as e:
        logger.error(f"스크린샷 업로드 실패 ({site}): {e}")
        return None


# 인터파크 공연 검색 → 상세 페이지 전체 스크린샷
async def crawl_interpark(concert: Concert) -> bytes | None:
    keyword = quote(concert.name)
    search_url = f"https://tickets.interpark.com/search?keyword={keyword}"

    try:
        async with async_playwright() as pw:
            browser, page = await _make_page(pw)
            try:
                await page.goto(search_url, wait_until="domcontentloaded", timeout=30_000)
                await page.wait_for_timeout(2_000)

                link = await page.query_selector('a[href*="/goods/"]')
                if link:
                    href = await link.get_attribute("href")
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
async def crawl_yes24(concert: Concert) -> bytes | None:
    keyword = quote(concert.name)
    search_url = f"https://ticket.yes24.com/New/Search/Search.aspx?q={keyword}"

    try:
        async with async_playwright() as pw:
            browser, page = await _make_page(pw)
            try:
                await page.goto(search_url, wait_until="domcontentloaded", timeout=30_000)
                await page.wait_for_timeout(2_000)

                link = await page.query_selector('a[href*="/New/Perf/"]')
                if link:
                    href = await link.get_attribute("href")
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


# 지원 사이트 → 크롤링 함수 매핑 (대소문자 정규화 후 조회)
_CRAWLERS: dict[str, callable] = {
    "INTERPARK": crawl_interpark,
    "인터파크": crawl_interpark,
    "YES24": crawl_yes24,
}


# 티켓 등록 백그라운드 태스크: 크롤링 후 Concert.crawl_screenshot_url 갱신
async def crawl_and_save(concert_id, ticketing_site: str | None) -> None:
    if not ticketing_site:
        return

    crawler = _CRAWLERS.get(ticketing_site.upper()) or _CRAWLERS.get(ticketing_site)
    if crawler is None:
        logger.info(f"크롤링 미지원 사이트: {ticketing_site}")
        return

    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Concert).where(Concert.id == concert_id))
        concert = result.scalar_one_or_none()
        if concert is None:
            return

        image_bytes = await crawler(concert)
        if image_bytes is None:
            return

        url = await _upload_screenshot(image_bytes, concert_id, ticketing_site.lower())
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
