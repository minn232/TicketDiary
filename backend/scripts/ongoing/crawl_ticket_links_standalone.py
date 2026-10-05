"""
독립 실행형 티켓 예매 링크 크롤러 - 이 파일 하나만 있으면 됨.

TicketDiary 백엔드 저장소(app/ 패키지 전체, DB, KOPIS API 키, S3 설정 등) 없이도 동작한다.
LLM팀처럼 백엔드 코드를 받지 않고 크롤링 이미지만 필요한 경우, 이 파일 하나만 복사해서 쓰면 됨.

필요한 것:
    pip install playwright playwright-stealth
    playwright install chromium

사용법:
    # URL 1개
    python crawl_ticket_links_standalone.py https://ticket.yes24.com/Perf/58933

    # URL 여러 개 (커맨드라인에 나열)
    python crawl_ticket_links_standalone.py <url1> <url2> <url3>

    # 파일로 일괄 처리 (한 줄에 URL 하나, '#'로 시작하는 줄은 주석)
    python crawl_ticket_links_standalone.py links.txt

지원 사이트: YES24/인터파크(구 "NOL 티켓")/NOL(야놀자, nol.yanolja.com)/멜론티켓은 전용 처리
(오픈전 페이지/멜론 Kakao 봇차단 감지/NOL의 "상품 상세 더보기" 자동 클릭 포함),
그 외 도메인(KOPIS 상세페이지, 네이버 예약 등)은 범용 스크린샷으로 폴백한다.
티켓링크(ticketlink.co.kr)는 Akamai 봇 차단으로 크롤링 자체가 불가능해 자동 스킵된다.

결과: ./crawled_images/<타임스탬프>_<슬러그>.png (--dir로 변경 가능)

주의: 이 파일은 backend/app/services/crawler.py의 크롤링 로직을 외부 배포용으로 복제한 것.
백엔드 쪽 크롤링 로직(오픈전 감지 키워드, 사이트별 셀렉터 등)이 나중에 바뀌면 이 파일은
자동으로 따라가지 않으니, 크게 갱신할 일이 있으면 crawler.py를 다시 보고 수동으로 반영할 것.
"""

import argparse
import asyncio
import logging
import re
import sys
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path
from urllib.parse import quote

from playwright.async_api import async_playwright
from playwright_stealth import Stealth

logger = logging.getLogger(__name__)

_IMAGE_DIR = Path(__file__).resolve().parent / "crawled_images"

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
@asynccontextmanager
async def _open_page(pw):
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
        yield page
    finally:
        await browser.close()


# 아직 정보가 없거나(티켓팅 오픈 전) 상품이 없는 페이지 감지용 키워드 - 사이트마다 실제 문구가
# 다르고 바뀔 수 있어 완벽하지 않음
_UNAVAILABLE_PAGE_KEYWORDS = [
    "검색결과가 없습니다",
    "검색 결과가 없습니다",
    "상품이 존재하지 않습니다",
    "판매중인 상품이 없습니다",
    "요청하신 페이지를 찾을 수 없습니다",
    "페이지를 찾을 수 없습니다",
    "오픈 예정",
    # "오픈예정"(공백 없음)은 인터파크 상단 내비게이션 카테고리 링크에 항상 존재해서 넣지 않음
    # (실제 공연 정보가 있는 정상 페이지까지 "오픈 전"으로 오판하는 false positive였음)
    "준비중입니다",
    "준비 중입니다",
    "등록된 공연이 없습니다",
]


async def _is_unavailable_page(page) -> bool:
    try:
        text = await page.inner_text("body")
    except Exception:
        return False
    return any(keyword in text for keyword in _UNAVAILABLE_PAGE_KEYWORDS)


# NOL(야놀자, nol.yanolja.com) 상세 페이지의 "상품 상세"/"공지사항" 섹션은 기본적으로 접혀있고
# 각각 "상품 상세 더보기"/"공지사항 더보기" 버튼을 직접 눌러야 전체 내용(라인업 포스터 이미지, 공지 전문)이 펼쳐짐
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
        # 스크롤된 지점에 고정된 채로 캡처되어 본문 이미지 중간에 겹쳐 나옴.
        # 스크린샷 직전에 항상 맨 위로 스크롤을 되돌려 이 문제를 방지한다
        try:
            await page.evaluate("window.scrollTo(0, 0)")
            await page.wait_for_timeout(200)
        except Exception as e:
            logger.warning(f"스크롤 리셋 실패 (무시하고 계속): {e}")


# 연령확인/이벤트배너/쿠키동의/"예매 안내" 같은 팝업이 스크린샷 위에 그대로 찍히는 걸 막기
# 위한 범용 닫기 로직. app/services/crawler.py와 동일한 로직(Chrome로 인터파크/멜론/YES24
# 실제 DOM 확인 + 실제 Playwright 헤드리스 실행으로 검증 완료) - 갱신 시 그쪽도 같이 볼 것.
# 클릭이 예외 없이 끝났다고 성공으로 치지 않고, 매 시도 후 컨테이너가 실제로 안 보이게
# 됐는지 재확인하면서 여러 방법을 순서대로 시도한다
_POPUP_CONTAINER_SELECTORS = (
    '[role="dialog"]',
    '[class*="alert" i]',
    '[class*="modal" i]',
    '[class*="popup" i]',
    '[class*="layer" i]',  # 국내 사이트에서 흔한 "레이어 팝업" 명명 관례
    '[class*="dim" i]',  # 배경을 어둡게 깔고 뜨는 오버레이를 감싸는 컨테이너 명명 관례
    '[class*="pop" i]',  # 가장 넓은 패턴이라 마지막 - 예고편 팝업/쿠폰 아이콘 등 관련없는 요소가
    # 훨씬 많이 섞여서(YES24 실측: 29개 중 진짜 공지 팝업은 뒤쪽 - 앞쪽을 잘못 클릭했다가 엉뚱한
    # 쿠폰 팝업을 열어버린 사고가 실제로 있었음) 우선순위를 가장 낮게 둠
)

_CONTAINER_CLASS_XPATH_COND = (
    "contains(@class,'modal') or contains(@class,'Modal') "
    "or contains(@class,'pop') or contains(@class,'Pop') "
    "or contains(@class,'layer') or contains(@class,'Layer') "
    "or contains(@class,'dim') or contains(@class,'Dim') "
    "or @role='dialog'"
)

_ATTR_CLOSE_SELECTORS = (
    '[aria-label*="닫기"]',
    '[aria-label*="close" i]',
    '[title*="닫기"]',
    '[class*="close" i]',
)

# 닫기/확인류 버튼 후보 텍스트. <button> 태그로 한정하지 않음(div/span/a로 만든 "버튼"도 흔함) -
# 대신 짧은 요소만 후보로 인정해서 본문 문단 중 우연히 같은 단어가 섞인 문장을 잘못 클릭하는 걸 방지
_CLOSE_TEXT_CANDIDATES = ("×", "✕", "X", "닫기", "확인")

# "예매 안내" 팝업 - 인터파크/YES24/멜론/티켓링크 등 대부분의 예매 사이트 상세 페이지에서
# 방문할 때마다(당일 재방문 제외) 뜨는 가장 흔한 팝업(실측 확인)
_BOOKING_NOTICE_SIGNAL_TEXTS = ("예매 안내", "예매안내")


async def _still_visible(locator) -> bool:
    try:
        return await locator.count() > 0 and await locator.is_visible()
    except Exception:
        return False


async def _try_close_container(page, container, allow_position_click: bool) -> bool:
    for selector in _ATTR_CLOSE_SELECTORS:
        try:
            btn = container.locator(selector).first
            if await btn.count() > 0 and await btn.is_visible():
                await btn.click(timeout=1_000)
                await page.wait_for_timeout(300)
                if not await _still_visible(container):
                    return True
        except Exception:
            continue

    # 텍스트 노드 자신은 스크린리더 전용이라 시각적으로 숨겨져 있고(예: 인터파크의
    # <button><span class="blind">닫기</span></button>) 실제 클릭 가능한 건 그 부모(버튼/링크/
    # role=button)인 경우가 흔함(실측 확인) - 텍스트 요소 자체가 안 보이면 가장 가까운 버튼류
    # 조상을 대신 찾아서 클릭한다
    for text in _CLOSE_TEXT_CANDIDATES:
        try:
            candidates = container.get_by_text(text, exact=False)
            count = min(await candidates.count(), 5)
            for i in range(count):
                candidate = candidates.nth(i)
                content = (await candidate.inner_text()).strip()
                if len(content) > 15:
                    continue

                clickable = candidate
                if not await candidate.is_visible():
                    ancestor_btn = candidate.locator(
                        "xpath=ancestor-or-self::*[self::button or self::a or @role='button'][1]"
                    ).first
                    if await ancestor_btn.count() > 0 and await ancestor_btn.is_visible():
                        clickable = ancestor_btn
                    else:
                        continue

                await clickable.click(timeout=1_000)
                await page.wait_for_timeout(300)
                if not await _still_visible(container):
                    return True
        except Exception:
            continue

    # 텍스트/속성/시맨틱 마커 어디에도 안 걸릴 정도로 순수 좌표 기반 클릭 핸들러만 있는 경우
    # 대응(실측 확인 - 멜론은 닫기 아이콘이 배경이미지고 클릭 핸들러가 헤더 div 전체에 걸려있어
    # 텍스트/속성으로 전혀 못 찾음). 팝업 우측 상단 모서리 근방 여러 지점을 순서대로 클릭
    if allow_position_click:
        try:
            box = await container.bounding_box()
            if box and box["width"] > 0 and box["height"] > 0:
                for dx, dy in ((15, 15), (25, 15), (15, 25), (10, 10), (30, 20)):
                    await page.mouse.click(box["x"] + box["width"] - dx, box["y"] + dy)
                    await page.wait_for_timeout(300)
                    if not await _still_visible(container):
                        return True
        except Exception:
            pass

    return False


async def _dismiss_popups(page) -> None:
    try:
        await page.keyboard.press("Escape")
        await page.wait_for_timeout(300)
    except Exception:
        pass

    # "예매 안내"/"예매안내"는 exact=True로 찾는다 - 부분 일치로 찾으면 "[휠체어석 예매 안내]"
    # 같은 전혀 다른 버튼이 먼저 걸려서 엉뚱한 걸 컨테이너로 잡는 경우가 실측으로 확인됨(멜론).
    # 실제 팝업 제목은 앞뒤에 다른 글자 없이 정확히 "예매 안내"/"예매안내"만 있음
    for signal_text in _BOOKING_NOTICE_SIGNAL_TEXTS:
        try:
            signals = page.get_by_text(signal_text, exact=True)
            signal = None
            for i in range(min(await signals.count(), 5)):
                candidate = signals.nth(i)
                if await candidate.is_visible():
                    signal = candidate
                    break
            if signal is None:
                continue

            # 조상 후보를 여러 개(가까운 것부터) 뽑아서 순서대로 시도 - 가장 가까운 조상이 팝업
            # 제목만 감싸는 좁은 헤더 div인 경우가 흔해서(인터파크의 popupHead 등, 실측 확인)
            # 하나만 시도하면 실제 닫기 버튼이 있는 바깥 컨테이너를 놓침
            containers = signal.locator(f"xpath=ancestor::*[{_CONTAINER_CLASS_XPATH_COND}]")
            ccount = min(await containers.count(), 4)
            if ccount == 0:
                if await _try_close_container(page, page, allow_position_click=False):
                    return
                continue

            for i in range(ccount):
                container = containers.nth(i)
                if await _try_close_container(page, container, allow_position_click=True):
                    return
        except Exception:
            continue

    # 위에서 못 닫았으면(제목 문구 자체가 없는 사이트 - YES24 등, 또는 다른 종류의 팝업 -
    # 연령확인/이벤트배너/쿠키동의 등) class/role 기반 범용 탐색으로 한 번 더 시도.
    # 여기도 `.first`만 쓰면 관련없는 다른 팝업(예: YES24의 예고편 재생용 "movie-pop-wrap"이
    # "pop-alert-box"보다 먼저 걸림, 실측 확인)을 잘못 잡을 수 있어 여러 후보를 순서대로 시도
    for container_selector in _POPUP_CONTAINER_SELECTORS:
        try:
            candidates = page.locator(container_selector)
            ccount = min(await candidates.count(), 5)
            for i in range(ccount):
                container = candidates.nth(i)
                if not await container.is_visible():
                    continue
                if await _try_close_container(page, container, allow_position_click=True):
                    return
        except Exception:
            continue


async def crawl_interpark(direct_url: str) -> bytes | None:
    try:
        async with async_playwright() as pw:
            async with _open_page(pw) as page:
                await page.goto(direct_url, wait_until="domcontentloaded", timeout=30_000)
                await page.wait_for_timeout(2_000)
                if await _is_unavailable_page(page):
                    logger.info(f"인터파크 아직 정보 없음/오픈 전으로 추정: {direct_url}")
                    return None
                await _dismiss_popups(page)
                await _expand_collapsed_sections(page)
                return await page.screenshot(full_page=True, type="png")
    except Exception as e:
        logger.warning(f"인터파크 크롤링 실패 ({direct_url}): {e}")
        return None


async def crawl_yes24(direct_url: str) -> bytes | None:
    try:
        async with async_playwright() as pw:
            async with _open_page(pw) as page:
                await page.goto(direct_url, wait_until="domcontentloaded", timeout=30_000)
                await page.wait_for_timeout(2_000)
                if await _is_unavailable_page(page):
                    logger.info(f"YES24 아직 정보 없음/오픈 전으로 추정: {direct_url}")
                    return None
                await _dismiss_popups(page)
                return await page.screenshot(full_page=True, type="png")
    except Exception as e:
        logger.warning(f"YES24 크롤링 실패 ({direct_url}): {e}")
        return None


async def crawl_melon(direct_url: str) -> bytes | None:
    try:
        async with async_playwright() as pw:
            async with _open_page(pw) as page:
                await page.goto(direct_url, wait_until="domcontentloaded", timeout=30_000)
                await page.wait_for_timeout(2_000)
                if "accounts.kakao.com" in page.url or "auth.kakao.com" in page.url:
                    logger.info(f"멜론티켓 봇 차단 감지 (Kakao 리다이렉트): {direct_url}")
                    return None
                if await _is_unavailable_page(page):
                    logger.info(f"멜론티켓 아직 정보 없음/오픈 전으로 추정: {direct_url}")
                    return None
                await _dismiss_popups(page)
                return await page.screenshot(full_page=True, type="png")
    except Exception as e:
        logger.warning(f"멜론티켓 크롤링 실패 ({direct_url}): {e}")
        return None


# 임의 URL을 직접 받아 전체 페이지 스크린샷 반환 (전용 크롤러가 없는 사이트용 범용 폴백)
async def crawl_url(url: str, wait_ms: int = 2000, verbose: bool = False) -> bytes | None:
    try:
        async with async_playwright() as pw:
            async with _open_page(pw) as page:
                await page.goto(url, wait_until="domcontentloaded", timeout=30_000)
                await page.wait_for_timeout(wait_ms)
                if verbose:
                    title = await page.title()
                    logger.info(f"[최종 URL] {page.url}")
                    logger.info(f"[페이지 제목] {title}")
                await _dismiss_popups(page)
                return await page.screenshot(full_page=True, type="png")
    except Exception as e:
        logger.warning(f"URL 크롤링 실패 ({url}): {e}")
        return None


# URL에 이 문자열이 포함되면 해당 전용 크롤러 사용 - 첫 매치 사용
# nol.yanolja.com은 인터파크와 무관한 별도 도메인이지만, "NOL 티켓"(interpark.com) 서비스가
# 종료되고 예매가 이 도메인으로 이관되는 중이라 같은 crawl_interpark로 묶어서 처리
_SITE_CRAWLERS_BY_DOMAIN = [
    ("yes24.com", crawl_yes24),
    ("interpark.com", crawl_interpark),
    ("nol.yanolja.com", crawl_interpark),
    ("melon.com", crawl_melon),
]

_TICKETLINK_DOMAIN = "ticketlink.co.kr"


def _slug(url: str) -> str:
    cleaned = re.sub(r"https?://", "", url)
    return re.sub(r"[^\w\-]", "_", cleaned).strip("_")[:80]


# 인자로 받은 각 target을 URL 목록으로 펼침 - 존재하는 파일 경로면 한 줄당 URL 하나로 읽고,
# 그냥 URL 문자열이면 1개짜리로 취급 (URL과 파일 경로를 섞어서 넘겨도 됨)
def _expand_targets(targets: list[str]) -> list[str]:
    urls: list[str] = []
    for target in targets:
        path = Path(target)
        if path.exists() and path.is_file():
            for line in path.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if line and not line.startswith("#"):
                    urls.append(line)
        else:
            urls.append(target.strip())
    return urls


def _pick_crawler(url: str):
    for domain, crawler in _SITE_CRAWLERS_BY_DOMAIN:
        if domain in url:
            return crawler
    return None


async def _crawl_one(url: str, wait_ms: int, verbose: bool) -> bytes | None:
    if _TICKETLINK_DOMAIN in url:
        print("  [✗] 티켓링크는 크롤링 불가(Akamai 봇 차단) - 스킵")
        return None

    crawler = _pick_crawler(url)
    if crawler is not None:
        return await crawler(url)

    return await crawl_url(url, wait_ms=wait_ms, verbose=verbose)


async def run(urls: list[str], out_dir: Path, wait_ms: int, verbose: bool) -> None:
    if verbose:
        logging.basicConfig(level=logging.INFO, format="%(message)s")

    out_dir.mkdir(parents=True, exist_ok=True)
    results: list[tuple[str, bool]] = []

    for i, url in enumerate(urls, 1):
        print(f"\n[{i}/{len(urls)}] {url}")
        image_bytes = await _crawl_one(url, wait_ms, verbose)
        if image_bytes is None:
            print("  [✗] 크롤링 실패")
            results.append((url, False))
            continue

        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
        out_path = out_dir / f"{timestamp}_{_slug(url)}.png"
        out_path.write_bytes(image_bytes)
        print(f"  [✓] 저장: {out_path.resolve()}  ({len(image_bytes) / 1024:.1f} KB)")
        results.append((url, True))

    print(f"\n{'─' * 60}")
    success = sum(ok for _, ok in results)
    print(f"총 {len(results)}건 중 {success}건 성공, {len(results) - success}건 실패")
    if success < len(results):
        print("실패 목록:")
        for url, ok in results:
            if not ok:
                print(f"  - {url}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="티켓 예매 링크 → 자동 크롤링 → 스크린샷 저장 (독립 실행형, 백엔드 저장소 불필요)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "targets", nargs="+",
        help="URL 1개 이상, 또는 URL 목록이 한 줄씩 담긴 파일 경로 (섞어서 지정 가능)",
    )
    parser.add_argument("--dir", help="출력 디렉터리 (기본값: ./crawled_images/)")
    parser.add_argument("--wait", type=int, default=2000, help="범용 크롤링(crawl_url) 시 추가 대기(ms)")
    parser.add_argument("--verbose", "-v", action="store_true", help="상세 로그 출력")

    args = parser.parse_args()
    urls = _expand_targets(args.targets)
    if not urls:
        print("[✗] 처리할 URL이 없습니다.", file=sys.stderr)
        sys.exit(1)

    out_dir = Path(args.dir) if args.dir else _IMAGE_DIR

    try:
        asyncio.run(run(urls, out_dir, args.wait, args.verbose))
    except KeyboardInterrupt:
        print("\n[!] 중단됨")
        sys.exit(1)
