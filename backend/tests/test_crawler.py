import asyncio
import uuid
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from app.services.crawler import (
    _pick_crawl_target,
    crawl_and_save,
    crawl_interpark,
    crawl_kopis,
    crawl_melon,
    crawl_yes24,
    retry_pending_crawls,
    send_screenshots_to_llm,
)


# 픽스처

@pytest.fixture
def mock_concert():
    concert = MagicMock()
    concert.id = uuid.uuid4()
    concert.name = "테스트 공연"
    concert.end_date = None
    return concert


def _make_pw_mock(
    screenshot: bytes,
    link_href: str | None = None,
    body_text: str = "정상적으로 로딩된 공연 상세 페이지 콘텐츠입니다",
    img_srcs: list[str] | None = None,
):
    mock_link = None
    if link_href:
        mock_link = AsyncMock()
        mock_link.get_attribute = AsyncMock(return_value=link_href)

    mock_page = AsyncMock()
    mock_page.goto = AsyncMock()
    mock_page.wait_for_timeout = AsyncMock()
    mock_page.query_selector = AsyncMock(return_value=mock_link)
    mock_page.screenshot = AsyncMock(return_value=screenshot)
    mock_page.inner_text = AsyncMock(return_value=body_text)
    mock_page.eval_on_selector_all = AsyncMock(return_value=img_srcs or [])

    mock_context = AsyncMock()
    mock_context.new_page = AsyncMock(return_value=mock_page)

    mock_browser = AsyncMock()
    mock_browser.new_context = AsyncMock(return_value=mock_context)
    mock_browser.close = AsyncMock()

    mock_pw = AsyncMock()
    mock_pw.chromium.launch = AsyncMock(return_value=mock_browser)

    mock_cm = AsyncMock()
    mock_cm.__aenter__ = AsyncMock(return_value=mock_pw)
    mock_cm.__aexit__ = AsyncMock(return_value=None)
    return mock_cm


# context.expect_page()의 async with ... as info / await info.value 흐름을 흉내내는 가짜 객체
# (인터파크 검색 결과 카드는 href 없이 클릭 시 새 탭으로 열려서 이 방식으로 감지해야 함)
class _FakeExpectPageCM:
    def __init__(self, page):
        self._page = page

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return None

    @property
    def value(self):
        async def _get():
            return self._page
        return _get()


# 인터파크 mock: 검색결과 카드 클릭 -> 새 탭(context.expect_page)으로 상세 페이지가 열리는 흐름 지원
def _make_interpark_pw_mock(screenshot: bytes, card_count: int = 0, detail_screenshot: bytes | None = None):
    body_text = "정상적으로 로딩된 공연 상세 페이지 콘텐츠입니다"

    mock_detail_page = AsyncMock()
    mock_detail_page.wait_for_load_state = AsyncMock()
    mock_detail_page.wait_for_timeout = AsyncMock()
    mock_detail_page.screenshot = AsyncMock(return_value=detail_screenshot or screenshot)
    mock_detail_page.inner_text = AsyncMock(return_value=body_text)

    mock_locator = AsyncMock()
    mock_locator.count = AsyncMock(return_value=card_count)
    mock_locator.click = AsyncMock()
    mock_locator.first = mock_locator

    mock_browser_context = MagicMock()
    mock_browser_context.expect_page = MagicMock(return_value=_FakeExpectPageCM(mock_detail_page))

    mock_page = AsyncMock()
    mock_page.goto = AsyncMock()
    mock_page.wait_for_timeout = AsyncMock()
    mock_page.inner_text = AsyncMock(return_value=body_text)
    mock_page.screenshot = AsyncMock(return_value=screenshot)
    mock_page.locator = MagicMock(return_value=mock_locator)
    mock_page.context = mock_browser_context

    mock_context = AsyncMock()
    mock_context.new_page = AsyncMock(return_value=mock_page)

    mock_browser = AsyncMock()
    mock_browser.new_context = AsyncMock(return_value=mock_context)
    mock_browser.close = AsyncMock()

    mock_pw = AsyncMock()
    mock_pw.chromium.launch = AsyncMock(return_value=mock_browser)

    mock_cm = AsyncMock()
    mock_cm.__aenter__ = AsyncMock(return_value=mock_pw)
    mock_cm.__aexit__ = AsyncMock(return_value=None)
    return mock_cm, mock_page, mock_detail_page


# crawl_interpark 테스트

# 검색 결과 카드가 없으면(검색결과 0건) 빈 페이지를 성공으로 오인하지 않고 None 반환
@pytest.mark.asyncio
async def test_crawl_interpark_no_results_returns_none(mock_concert):
    pw_mock, _, _ = _make_interpark_pw_mock(b"empty-search-page-png", card_count=0)
    with patch("app.services.crawler.async_playwright", return_value=pw_mock):
        result = await crawl_interpark(mock_concert)
    assert result is None


# 검색 결과 카드 발견 시 클릭 -> 새 탭으로 열린 상세 페이지를 스크린샷
@pytest.mark.asyncio
async def test_crawl_interpark_navigates_to_detail(mock_concert):
    expected = b"detail-png"
    pw_mock, _, mock_detail_page = _make_interpark_pw_mock(
        b"search-png", card_count=1, detail_screenshot=expected
    )
    with patch("app.services.crawler.async_playwright", return_value=pw_mock):
        result = await crawl_interpark(mock_concert)
    assert result == expected
    mock_detail_page.screenshot.assert_awaited_once()


# 검색 URL에 CLOSED 상태를 포함해 이미 끝난 공연도 검색되는지 확인
# (NOL 리브랜딩 후 기본 /search는 판매중/예정만 조회해 종료된 공연은 0건 -> 검색결과 카드가 아예 안 뜸)
@pytest.mark.asyncio
async def test_crawl_interpark_search_url_includes_closed_status(mock_concert):
    pw_mock, mock_page, _ = _make_interpark_pw_mock(b"png-bytes", card_count=0)
    with patch("app.services.crawler.async_playwright", return_value=pw_mock):
        await crawl_interpark(mock_concert)

    called_url = mock_page.goto.call_args_list[0].args[0]
    assert called_url.startswith("https://tickets.interpark.com/contents/search")
    assert "status=CLOSED" in called_url


# Playwright 예외 시 None 반환
@pytest.mark.asyncio
async def test_crawl_interpark_returns_none_on_error(mock_concert):
    mock_cm = AsyncMock()
    mock_cm.__aenter__ = AsyncMock(side_effect=Exception("timeout"))
    mock_cm.__aexit__ = AsyncMock(return_value=None)
    with patch("app.services.crawler.async_playwright", return_value=mock_cm):
        result = await crawl_interpark(mock_concert)
    assert result is None


# ticketing_links의 direct_url로 바로 들어갔을 때 정상 페이지면 스크린샷 반환
@pytest.mark.asyncio
async def test_crawl_interpark_direct_url_returns_screenshot(mock_concert):
    expected = b"interpark-direct-png"
    pw_mock = _make_pw_mock(expected, body_text="공연 상세 정보: R석 110,000원, 예매하기 버튼 활성화됨")
    with patch("app.services.crawler.async_playwright", return_value=pw_mock):
        result = await crawl_interpark(mock_concert, direct_url="https://tickets.interpark.com/goods/12345")
    assert result == expected


# ticketing_links의 direct_url로 바로 들어갔는데 아직 오픈 전/빈 페이지면 None 반환(스크린샷 안 찍음)
# - KOPIS엔 이미 등록됐지만 예매 사이트에 실제 판매 페이지가 아직 없는 경우를 걸러내기 위함
@pytest.mark.asyncio
async def test_crawl_interpark_direct_url_unavailable_returns_none(mock_concert):
    pw_mock = _make_pw_mock(b"placeholder-png", body_text="죄송합니다. 오픈 예정 상품입니다.")
    with patch("app.services.crawler.async_playwright", return_value=pw_mock):
        result = await crawl_interpark(mock_concert, direct_url="https://tickets.interpark.com/goods/12345")
    assert result is None


# 인터파크 상단 내비게이션에 항상 있는 "오픈예정"(공백 없음) 카테고리 링크 때문에, 정상적으로
# 공연 정보가 있는 페이지까지 "오픈 전"으로 오판되던 회귀 방지 테스트 (실제 크롤링으로 발견,
# 2026-07-29 - scripts/test_lineup_diff.py로 https://tickets.interpark.com/goods/26009383 확인)
@pytest.mark.asyncio
async def test_crawl_interpark_direct_url_nav_menu_open_pending_link_not_false_positive(mock_concert):
    expected = b"interpark-direct-png"
    body_text = (
        "홈 투어 티켓 로그인 내 예약 뮤지컬 콘서트 스포츠 전시/행사 클래식/무용 아동/가족 연극 "
        "레저/캠핑 토핑 MD shop 랭킹 오픈예정 지역별 공연장\n2026 Asia Top Artist Festival\n캐스팅"
    )
    pw_mock = _make_pw_mock(expected, body_text=body_text)
    with patch("app.services.crawler.async_playwright", return_value=pw_mock):
        result = await crawl_interpark(mock_concert, direct_url="https://tickets.interpark.com/goods/26009383")
    assert result == expected


# _expand_collapsed_sections 테스트 (NOL(야놀자) "상품 상세 더보기"/"공지사항 더보기" 버튼 대응)

# 버튼 텍스트별로 다른 locator mock을 반환하는 헬퍼 (실제 page.locator(f'button:has-text("{text}")')
# 호출을 셀렉터별로 구분해서 검증하기 위함)
def _make_locator_by_text(counts: dict[str, int]):
    locators = {}
    for text, count in counts.items():
        loc = AsyncMock()
        loc.count = AsyncMock(return_value=count)
        loc.click = AsyncMock()
        locators[f'button:has-text("{text}")'] = loc

    def _locator(selector):
        return locators[selector]

    return _locator, locators


@pytest.mark.asyncio
async def test_expand_collapsed_sections_clicks_both_when_both_present():
    from app.services.crawler import _expand_collapsed_sections

    locator_fn, locators = _make_locator_by_text({"상품 상세 더보기": 1, "공지사항 더보기": 1})

    mock_page = AsyncMock()
    mock_page.locator = MagicMock(side_effect=locator_fn)
    mock_page.wait_for_timeout = AsyncMock()
    mock_page.evaluate = AsyncMock()

    await _expand_collapsed_sections(mock_page)

    locators['button:has-text("상품 상세 더보기")'].click.assert_awaited_once()
    locators['button:has-text("공지사항 더보기")'].click.assert_awaited_once()
    # 클릭이 요소를 뷰포트로 자동 스크롤시켜 놓은 상태 그대로 스크린샷을 찍으면 position:fixed
    # 헤더가 스크롤된 지점에 고정된 채로 찍히는 회귀 방지 - 클릭 후 맨 위로 스크롤을 되돌려야 함
    # (버튼 2개를 각각 클릭해도 리셋은 한 번만 하면 충분)
    mock_page.evaluate.assert_awaited_once_with("window.scrollTo(0, 0)")


# 둘 중 하나만 있어도(구 인터파크처럼 상품상세는 없고 공지사항만 접혀있는 경우 등) 있는 것만
# 클릭하고 리셋은 그대로 수행하는지 테스트
@pytest.mark.asyncio
async def test_expand_collapsed_sections_clicks_only_the_one_present():
    from app.services.crawler import _expand_collapsed_sections

    locator_fn, locators = _make_locator_by_text({"상품 상세 더보기": 0, "공지사항 더보기": 1})

    mock_page = AsyncMock()
    mock_page.locator = MagicMock(side_effect=locator_fn)
    mock_page.wait_for_timeout = AsyncMock()
    mock_page.evaluate = AsyncMock()

    await _expand_collapsed_sections(mock_page)

    locators['button:has-text("상품 상세 더보기")'].click.assert_not_called()
    locators['button:has-text("공지사항 더보기")'].click.assert_awaited_once()
    mock_page.evaluate.assert_awaited_once_with("window.scrollTo(0, 0)")


# 구 인터파크 페이지처럼 두 버튼 다 없으면(count()==0) 클릭도 스크롤 리셋도 안 하는지 테스트
@pytest.mark.asyncio
async def test_expand_collapsed_sections_noop_when_neither_present():
    from app.services.crawler import _expand_collapsed_sections

    locator_fn, locators = _make_locator_by_text({"상품 상세 더보기": 0, "공지사항 더보기": 0})

    mock_page = AsyncMock()
    mock_page.locator = MagicMock(side_effect=locator_fn)
    mock_page.evaluate = AsyncMock()

    await _expand_collapsed_sections(mock_page)

    for loc in locators.values():
        loc.click.assert_not_called()
    mock_page.evaluate.assert_not_called()


# 버튼 탐색/클릭 중 예외가 나도(한쪽만 실패해도) 크롤링 전체를 실패시키지 않고, 나머지 버튼은
# 계속 시도하는지 테스트
@pytest.mark.asyncio
async def test_expand_collapsed_sections_swallows_errors_and_continues():
    from app.services.crawler import _expand_collapsed_sections

    ok_locator = AsyncMock()
    ok_locator.count = AsyncMock(return_value=1)
    ok_locator.click = AsyncMock()

    def _locator(selector):
        if "상품 상세" in selector:
            raise RuntimeError("페이지 닫힘")
        return ok_locator

    mock_page = AsyncMock()
    mock_page.locator = MagicMock(side_effect=_locator)
    mock_page.wait_for_timeout = AsyncMock()
    mock_page.evaluate = AsyncMock()

    await _expand_collapsed_sections(mock_page)  # 예외 없이 반환되면 통과

    ok_locator.click.assert_awaited_once()
    mock_page.evaluate.assert_awaited_once_with("window.scrollTo(0, 0)")


# ticketing_links의 INTERPARK 키에 nol.yanolja.com URL이 들어온 경우("NOL 티켓" -> "NOL(야놀자)"
# 이관, 2026-09-08부로 구 서비스 종료) "상품 상세 더보기" 버튼을 클릭한 뒤 스크린샷을 찍는지 테스트
@pytest.mark.asyncio
async def test_crawl_interpark_direct_url_expands_nol_yanolja_show_more(mock_concert):
    expected = b"nol-yanolja-expanded-png"

    mock_show_more = AsyncMock()
    mock_show_more.count = AsyncMock(return_value=1)
    mock_show_more.click = AsyncMock()

    mock_page = AsyncMock()
    mock_page.goto = AsyncMock()
    mock_page.wait_for_timeout = AsyncMock()
    mock_page.inner_text = AsyncMock(return_value="정상적으로 로딩된 공연 상세 페이지 콘텐츠입니다")
    mock_page.locator = MagicMock(return_value=mock_show_more)
    mock_page.screenshot = AsyncMock(return_value=expected)

    mock_context = AsyncMock()
    mock_context.new_page = AsyncMock(return_value=mock_page)
    mock_browser = AsyncMock()
    mock_browser.new_context = AsyncMock(return_value=mock_context)
    mock_browser.close = AsyncMock()
    mock_pw = AsyncMock()
    mock_pw.chromium.launch = AsyncMock(return_value=mock_browser)
    mock_cm = AsyncMock()
    mock_cm.__aenter__ = AsyncMock(return_value=mock_pw)
    mock_cm.__aexit__ = AsyncMock(return_value=None)

    with patch("app.services.crawler.async_playwright", return_value=mock_cm):
        result = await crawl_interpark(
            mock_concert, direct_url="https://nol.yanolja.com/ticket/products/26010721"
        )

    assert result == expected
    # mock_page.locator가 셀렉터와 무관하게 같은 mock을 반환하므로, "상품 상세 더보기"/
    # "공지사항 더보기" 두 버튼 각각에 대해 한 번씩 총 2번 클릭됨
    assert mock_show_more.click.await_count == 2


# crawl_yes24 테스트

# 링크 없어도 검색 결과 페이지 스크린샷 반환
@pytest.mark.asyncio
async def test_crawl_yes24_search_page_screenshot(mock_concert):
    expected = b"yes24-png"
    with patch("app.services.crawler.async_playwright", return_value=_make_pw_mock(expected)):
        result = await crawl_yes24(mock_concert)
    assert result == expected


# Perf/ 링크 발견 시 상세 페이지로 이동
@pytest.mark.asyncio
async def test_crawl_yes24_navigates_to_detail(mock_concert):
    expected = b"yes24-detail-png"
    pw_mock = _make_pw_mock(expected, link_href="/New/Perf/99999/Info")
    with patch("app.services.crawler.async_playwright", return_value=pw_mock):
        result = await crawl_yes24(mock_concert)
    assert result == expected


# Playwright 예외 시 None 반환
@pytest.mark.asyncio
async def test_crawl_yes24_returns_none_on_error(mock_concert):
    mock_cm = AsyncMock()
    mock_cm.__aenter__ = AsyncMock(side_effect=Exception("bot block"))
    mock_cm.__aexit__ = AsyncMock(return_value=None)
    with patch("app.services.crawler.async_playwright", return_value=mock_cm):
        result = await crawl_yes24(mock_concert)
    assert result is None


# ticketing_links의 direct_url로 바로 들어갔는데 아직 오픈 전/빈 페이지면 None 반환
@pytest.mark.asyncio
async def test_crawl_yes24_direct_url_unavailable_returns_none(mock_concert):
    pw_mock = _make_pw_mock(b"placeholder-png", body_text="검색결과가 없습니다.")
    with patch("app.services.crawler.async_playwright", return_value=pw_mock):
        result = await crawl_yes24(mock_concert, direct_url="https://ticket.yes24.com/New/Perf/99999")
    assert result is None


# 봇 차단 페이지 감지 테스트 (실측: YES24가 한 달 내내 아래 문구의 차단 페이지만 캡처됨)
@pytest.mark.asyncio
async def test_crawl_yes24_returns_none_on_blocked_page(mock_concert):
    body_text = (
        "비정상적인 접근으로 일시적으로 서비스 접속이 제한 되었습니다.\n"
        "Restricted access to service. your access has been restricted due to policy violations. Code: 72"
    )
    pw_mock = _make_pw_mock(b"blocked-png", body_text=body_text)
    with patch("app.services.crawler.async_playwright", return_value=pw_mock):
        result = await crawl_yes24(mock_concert, direct_url="https://ticket.yes24.com/Perf/1")
    assert result is None


# 빈 페이지 감지 테스트 (실측: 멜론에서 5KB 완전 흰 화면만 반복 캡처됨)
@pytest.mark.asyncio
async def test_crawl_melon_returns_none_on_blank_page(mock_concert):
    pw_mock = _make_melon_pw_mock(b"blank-png", body_text="")
    with patch("app.services.crawler.async_playwright", return_value=pw_mock):
        result = await crawl_melon(mock_concert, direct_url="https://ticket.melon.com/performance/index.htm?prodId=1")
    assert result is None


# NOL 티켓(인터파크 리브랜딩) 별칭 테스트

# "NOL ticket"/"NOL" 표기가 INTERPARK 크롤러로 정규화되는지 확인
@pytest.mark.parametrize("ticketing_site", ["NOL ticket", "NOL", "nol", "Nol Ticket", "NOL티켓"])
def test_pick_crawl_target_nol_variants_resolve_to_interpark(ticketing_site):
    site_key, direct_url = _pick_crawl_target(ticketing_site, None)
    assert site_key == "INTERPARK"
    assert direct_url is None


# ticketing_links에 인터파크 직접 URL이 있으면 NOL 표기여도 그 URL을 그대로 사용
def test_pick_crawl_target_nol_prefers_direct_interpark_link():
    site_key, direct_url = _pick_crawl_target(
        "NOL ticket", {"INTERPARK": "https://tickets.interpark.com/goods/12345"}
    )
    assert site_key == "INTERPARK"
    assert direct_url == "https://tickets.interpark.com/goods/12345"


# _pick_crawl_candidates / _crawl_first_success 테스트 (한 사이트가 계속 차단당해도 다음
# 우선순위 사이트로 넘어갈 수 있게 하는 폴백 로직 - YES24 한 달째 100% 차단 대응)

# 등록된 링크가 있는 우선순위 사이트를 전부 후보로, _PREFERRED_SITES 순서 그대로 반환하는지 확인.
# 지금은 YES24/MELON이 임시 비활성화라(_TEMPORARILY_DISABLED_SITES) _PREFERRED_SITES에 INTERPARK만
# 있음 - 링크가 있어도 후보에서 제외되는지 함께 확인
def test_pick_crawl_candidates_returns_all_preferred_sites_in_order():
    from app.services.crawler import _pick_crawl_candidates

    candidates = _pick_crawl_candidates(
        None,
        {
            "MELON": "https://ticket.melon.com/performance/index.htm?prodId=1",
            "YES24": "https://ticket.yes24.com/Perf/1",
            "INTERPARK": "https://tickets.interpark.com/goods/1",
        },
    )
    assert [site for site, _ in candidates] == ["INTERPARK"]


# 우선순위 사이트 링크가 하나도 없어도 명시적으로 전달된 ticketing_site는 마지막 후보로 포함.
# 단, 임시 비활성화된 사이트(MELON)는 명시적으로 지정돼도 후보에서 제외됨
def test_pick_crawl_candidates_appends_ticketing_site_as_fallback():
    from app.services.crawler import _pick_crawl_candidates

    candidates = _pick_crawl_candidates("TICKETLINK", None)
    assert candidates == []  # TICKETLINK는 _UNSUPPORTED_SITES라 후보에서 제외됨

    candidates = _pick_crawl_candidates("MELON", None)
    assert candidates == []  # MELON은 _TEMPORARILY_DISABLED_SITES라 후보에서 제외됨

    candidates = _pick_crawl_candidates("INTERPARK", None)
    assert candidates == [("INTERPARK", None)]


# 1순위 후보가 실패(None 반환)해도 다음 후보로 넘어가 성공하면 그 결과를 반환하는지 확인
@pytest.mark.asyncio
async def test_crawl_first_success_falls_back_to_next_candidate(mock_concert):
    from app.services.crawler import _crawl_first_success

    blocked_crawler = AsyncMock(return_value=None)
    working_crawler = AsyncMock(return_value=b"interpark-bytes")

    candidates = [("YES24", "https://ticket.yes24.com/Perf/1"), ("INTERPARK", "https://tickets.interpark.com/goods/1")]
    with patch.dict(
        "app.services.crawler._CRAWLERS", {"YES24": blocked_crawler, "INTERPARK": working_crawler}
    ):
        site_key, result = await _crawl_first_success(mock_concert, candidates)

    assert site_key == "INTERPARK"
    assert result == b"interpark-bytes"
    blocked_crawler.assert_awaited_once()
    working_crawler.assert_awaited_once()


# 모든 후보가 실패하면 (None, None) 반환
@pytest.mark.asyncio
async def test_crawl_first_success_all_fail_returns_none(mock_concert):
    from app.services.crawler import _crawl_first_success

    candidates = [("YES24", "https://ticket.yes24.com/Perf/1"), ("MELON", "https://ticket.melon.com/1")]
    with patch.dict(
        "app.services.crawler._CRAWLERS",
        {"YES24": AsyncMock(return_value=None), "MELON": AsyncMock(return_value=None)},
    ):
        site_key, result = await _crawl_first_success(mock_concert, candidates)

    assert (site_key, result) == (None, None)


# crawl_and_save 통합 테스트: YES24는 임시 비활성화 상태라(_TEMPORARILY_DISABLED_SITES) 링크가
# 있어도 아예 시도하지 않고 INTERPARK 후보로 바로 저장되는지 확인
@pytest.mark.asyncio
async def test_crawl_and_save_skips_temporarily_disabled_site():
    concert_id = uuid.uuid4()
    fake_url = "https://s3.example.com/crawls/screenshot.png"

    mock_concert = MagicMock()
    mock_concert.crawl_attempt_count = 0
    mock_concert.id = concert_id
    mock_concert.name = "공연명"
    mock_concert.ticketing_links = {
        "YES24": "https://ticket.yes24.com/Perf/1",
        "INTERPARK": "https://tickets.interpark.com/goods/1",
    }
    mock_concert.crawl_screenshot_url = None
    mock_concert.ticketing_date = None
    mock_concert.end_date = None
    mock_concert.crawl_attempted_at = None

    mock_db = AsyncMock()
    mock_db.execute = AsyncMock(return_value=MagicMock(scalar_one_or_none=MagicMock(return_value=mock_concert)))
    mock_db.commit = AsyncMock()
    mock_db.__aenter__ = AsyncMock(return_value=mock_db)
    mock_db.__aexit__ = AsyncMock(return_value=None)

    yes24_crawler = AsyncMock(return_value=None)
    interpark_crawler = AsyncMock(return_value=b"interpark-bytes")

    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch.dict("app.services.crawler._CRAWLERS", {"YES24": yes24_crawler, "INTERPARK": interpark_crawler}),
        patch("app.services.crawler._upload_screenshot", new=AsyncMock(return_value=fake_url)),
    ):
        await crawl_and_save(concert_id)

    yes24_crawler.assert_not_awaited()  # 임시 비활성화라 아예 시도 안 함
    interpark_crawler.assert_awaited_once()
    assert mock_concert.crawl_screenshot_url == fake_url


# _make_page 테스트

# browser.new_context 단계에서 실패해도 이미 launch된 browser가 닫히는지 테스트
# (반환 전에 예외가 나면 호출부의 try/finally가 걸리지 못해 브라우저 프로세스가 누수되던 버그 회귀 방지)
@pytest.mark.asyncio
async def test_make_page_closes_browser_on_context_creation_failure():
    from app.services.crawler import _make_page

    mock_browser = AsyncMock()
    mock_browser.new_context = AsyncMock(side_effect=RuntimeError("컨텍스트 생성 실패"))
    mock_browser.close = AsyncMock()

    mock_pw = AsyncMock()
    mock_pw.chromium.launch = AsyncMock(return_value=mock_browser)

    with pytest.raises(RuntimeError):
        await _make_page(mock_pw)

    mock_browser.close.assert_awaited_once()


# stealth 적용 단계에서 실패해도 이미 launch된 browser가 닫히는지 테스트
@pytest.mark.asyncio
async def test_make_page_closes_browser_on_stealth_failure():
    from app.services.crawler import _make_page

    mock_context = AsyncMock()
    mock_browser = AsyncMock()
    mock_browser.new_context = AsyncMock(return_value=mock_context)
    mock_browser.close = AsyncMock()

    mock_pw = AsyncMock()
    mock_pw.chromium.launch = AsyncMock(return_value=mock_browser)

    with patch(
        "app.services.crawler._STEALTH.apply_stealth_async",
        AsyncMock(side_effect=RuntimeError("stealth 실패")),
    ):
        with pytest.raises(RuntimeError):
            await _make_page(mock_pw)

    mock_browser.close.assert_awaited_once()


# crawl_and_save 테스트

# NOL ticket으로 등록된 티켓도 INTERPARK 크롤러로 처리되는지 확인
@pytest.mark.asyncio
async def test_crawl_and_save_nol_ticket_uses_interpark_crawler():
    concert_id = uuid.uuid4()
    fake_url = "https://s3.example.com/crawls/screenshot.png"

    mock_concert = MagicMock()
    mock_concert.crawl_attempt_count = 0
    mock_concert.id = concert_id
    mock_concert.name = "공연명"
    mock_concert.ticketing_links = None
    mock_concert.crawl_screenshot_url = None
    mock_concert.ticketing_date = None
    mock_concert.end_date = None
    mock_concert.crawl_attempted_at = None

    mock_db = AsyncMock()
    mock_db.execute = AsyncMock(return_value=MagicMock(scalar_one_or_none=MagicMock(return_value=mock_concert)))
    mock_db.commit = AsyncMock()
    mock_db.__aenter__ = AsyncMock(return_value=mock_db)
    mock_db.__aexit__ = AsyncMock(return_value=None)

    mock_crawler = AsyncMock(return_value=b"bytes")

    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch.dict("app.services.crawler._CRAWLERS", {"INTERPARK": mock_crawler}),
        patch("app.services.crawler._upload_screenshot", new=AsyncMock(return_value=fake_url)),
    ):
        await crawl_and_save(concert_id, "NOL ticket")

    mock_crawler.assert_awaited_once()
    assert mock_concert.crawl_screenshot_url == fake_url


# INTERPARK 크롤링 성공 시 Concert.crawl_screenshot_url 저장
@pytest.mark.asyncio
async def test_crawl_and_save_interpark_updates_concert():
    concert_id = uuid.uuid4()
    fake_url = "https://s3.example.com/crawls/screenshot.png"

    mock_concert = MagicMock()
    mock_concert.crawl_attempt_count = 0
    mock_concert.id = concert_id
    mock_concert.name = "공연명"
    mock_concert.crawl_screenshot_url = None
    mock_concert.ticketing_date = None
    mock_concert.end_date = None
    mock_concert.crawl_attempted_at = None

    mock_db = AsyncMock()
    mock_db.execute = AsyncMock(return_value=MagicMock(scalar_one_or_none=MagicMock(return_value=mock_concert)))
    mock_db.commit = AsyncMock()
    mock_db.__aenter__ = AsyncMock(return_value=mock_db)
    mock_db.__aexit__ = AsyncMock(return_value=None)

    mock_crawler = AsyncMock(return_value=b"bytes")

    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch.dict("app.services.crawler._CRAWLERS", {"INTERPARK": mock_crawler}),
        patch("app.services.crawler._upload_screenshot", new=AsyncMock(return_value=fake_url)),
    ):
        await crawl_and_save(concert_id, "INTERPARK")

    assert mock_concert.crawl_screenshot_url == fake_url
    mock_db.commit.assert_awaited()


# 미지원 사이트 + ticketing_links도 없으면 크롤링 없이 종료
@pytest.mark.asyncio
async def test_crawl_and_save_unsupported_site_skips():
    concert_id = uuid.uuid4()
    mock_concert = MagicMock()
    mock_concert.crawl_attempt_count = 0
    mock_concert.id = concert_id
    mock_concert.name = "공연명"
    mock_concert.crawl_screenshot_url = None
    mock_concert.ticketing_links = None
    mock_concert.ticketing_date = None
    mock_concert.end_date = None
    mock_concert.crawl_attempted_at = None

    mock_db = AsyncMock()
    mock_db.execute = AsyncMock(return_value=MagicMock(scalar_one_or_none=MagicMock(return_value=mock_concert)))
    mock_db.__aenter__ = AsyncMock(return_value=mock_db)
    mock_db.__aexit__ = AsyncMock(return_value=None)

    with patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db):
        await crawl_and_save(concert_id, "UNKNOWN_SITE")

    mock_db.commit.assert_not_awaited()


# ticketing_site=None이고 ticketing_links도 없으면 크롤링 없이 종료
@pytest.mark.asyncio
async def test_crawl_and_save_none_ticketing_site_and_no_links_skips():
    concert_id = uuid.uuid4()
    mock_concert = MagicMock()
    mock_concert.crawl_attempt_count = 0
    mock_concert.id = concert_id
    mock_concert.name = "공연명"
    mock_concert.crawl_screenshot_url = None
    mock_concert.ticketing_links = None
    mock_concert.ticketing_date = None
    mock_concert.end_date = None
    mock_concert.crawl_attempted_at = None

    mock_db = AsyncMock()
    mock_db.execute = AsyncMock(return_value=MagicMock(scalar_one_or_none=MagicMock(return_value=mock_concert)))
    mock_db.__aenter__ = AsyncMock(return_value=mock_db)
    mock_db.__aexit__ = AsyncMock(return_value=None)

    with patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db):
        await crawl_and_save(concert_id, None)

    mock_db.commit.assert_not_awaited()


# ticketing_site=None이어도(예: 찜 시점처럼 아직 아무도 티켓 등록 안 한 경우) concert.ticketing_links만
# 있으면 그걸로 크롤링을 진행하는지 테스트 (KOPIS 상세조회 때 이미 채워진 예매 링크 활용)
@pytest.mark.asyncio
async def test_crawl_and_save_none_ticketing_site_uses_ticketing_links():
    concert_id = uuid.uuid4()
    fake_url = "https://s3.example.com/crawls/screenshot.png"

    mock_concert = MagicMock()
    mock_concert.crawl_attempt_count = 0
    mock_concert.id = concert_id
    mock_concert.name = "공연명"
    mock_concert.crawl_screenshot_url = None
    mock_concert.ticketing_links = {"INTERPARK": "https://tickets.interpark.com/goods/12345"}
    mock_concert.ticketing_date = None
    mock_concert.end_date = None
    mock_concert.crawl_attempted_at = None

    mock_db = AsyncMock()
    mock_db.execute = AsyncMock(return_value=MagicMock(scalar_one_or_none=MagicMock(return_value=mock_concert)))
    mock_db.commit = AsyncMock()
    mock_db.__aenter__ = AsyncMock(return_value=mock_db)
    mock_db.__aexit__ = AsyncMock(return_value=None)

    mock_crawler = AsyncMock(return_value=b"bytes")
    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch.dict("app.services.crawler._CRAWLERS", {"INTERPARK": mock_crawler}),
        patch("app.services.crawler._upload_screenshot", new=AsyncMock(return_value=fake_url)),
    ):
        await crawl_and_save(concert_id, None)

    mock_crawler.assert_awaited_once()
    assert mock_concert.crawl_screenshot_url == fake_url


# 이미 ticketing_date를 얻은 공연은 더 크롤링할 필요 없으므로 재크롤링 없이 종료
@pytest.mark.asyncio
async def test_crawl_and_save_skips_when_ticketing_date_known():
    concert_id = uuid.uuid4()
    mock_concert = MagicMock()
    mock_concert.crawl_attempt_count = 0
    mock_concert.id = concert_id
    mock_concert.name = "공연명"
    mock_concert.crawl_screenshot_url = "https://s3.example.com/crawls/existing.png"
    mock_concert.ticketing_date = datetime(2030, 4, 1, tzinfo=timezone.utc)

    mock_db = AsyncMock()
    mock_db.execute = AsyncMock(return_value=MagicMock(scalar_one_or_none=MagicMock(return_value=mock_concert)))
    mock_db.commit = AsyncMock()
    mock_db.__aenter__ = AsyncMock(return_value=mock_db)
    mock_db.__aexit__ = AsyncMock(return_value=None)

    mock_crawler = AsyncMock(return_value=b"bytes")
    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch.dict("app.services.crawler._CRAWLERS", {"INTERPARK": mock_crawler}),
        patch("app.services.crawler._upload_screenshot", new=AsyncMock()) as mock_upload,
    ):
        await crawl_and_save(concert_id, "INTERPARK")

    mock_crawler.assert_not_called()
    mock_upload.assert_not_called()
    mock_db.commit.assert_not_awaited()


# 공연이 이미 끝났으면 재크롤링 없이 종료
@pytest.mark.asyncio
async def test_crawl_and_save_skips_when_concert_ended():
    concert_id = uuid.uuid4()
    mock_concert = MagicMock()
    mock_concert.crawl_attempt_count = 0
    mock_concert.id = concert_id
    mock_concert.name = "공연명"
    mock_concert.crawl_screenshot_url = None
    mock_concert.ticketing_date = None
    mock_concert.end_date = datetime(2020, 1, 1, tzinfo=timezone.utc)  # 이미 지난 공연

    mock_db = AsyncMock()
    mock_db.execute = AsyncMock(return_value=MagicMock(scalar_one_or_none=MagicMock(return_value=mock_concert)))
    mock_db.commit = AsyncMock()
    mock_db.__aenter__ = AsyncMock(return_value=mock_db)
    mock_db.__aexit__ = AsyncMock(return_value=None)

    mock_crawler = AsyncMock(return_value=b"bytes")
    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch.dict("app.services.crawler._CRAWLERS", {"INTERPARK": mock_crawler}),
        patch("app.services.crawler._upload_screenshot", new=AsyncMock()) as mock_upload,
    ):
        await crawl_and_save(concert_id, "INTERPARK")

    mock_crawler.assert_not_called()
    mock_upload.assert_not_called()
    mock_db.commit.assert_not_awaited()


# 최근에 이미 크롤링을 시도했으면(쿨다운 이내) 재시도하지 않고 종료
@pytest.mark.asyncio
async def test_crawl_and_save_skips_within_cooldown():
    concert_id = uuid.uuid4()
    mock_concert = MagicMock()
    mock_concert.crawl_attempt_count = 0
    mock_concert.id = concert_id
    mock_concert.name = "공연명"
    mock_concert.crawl_screenshot_url = "https://s3.example.com/crawls/placeholder.png"
    mock_concert.ticketing_date = None
    mock_concert.end_date = None
    mock_concert.crawl_attempted_at = datetime.now(timezone.utc) - timedelta(hours=1)  # 24시간 이내

    mock_db = AsyncMock()
    mock_db.execute = AsyncMock(return_value=MagicMock(scalar_one_or_none=MagicMock(return_value=mock_concert)))
    mock_db.commit = AsyncMock()
    mock_db.__aenter__ = AsyncMock(return_value=mock_db)
    mock_db.__aexit__ = AsyncMock(return_value=None)

    mock_crawler = AsyncMock(return_value=b"bytes")
    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch.dict("app.services.crawler._CRAWLERS", {"INTERPARK": mock_crawler}),
        patch("app.services.crawler._upload_screenshot", new=AsyncMock()) as mock_upload,
    ):
        await crawl_and_save(concert_id, "INTERPARK")

    mock_crawler.assert_not_called()
    mock_upload.assert_not_called()
    mock_db.commit.assert_not_awaited()


# 쿨다운이 지났고 ticketing_date를 아직 못 얻었으면(기존에 스크린샷이 있었어도) 재시도하는지 테스트
# (KOPIS에 먼저 등록되고 예매 사이트가 나중에 열리는 경우, 예전엔 첫 스크린샷 이후 영원히 재시도 안 됐음)
@pytest.mark.asyncio
async def test_crawl_and_save_retries_after_cooldown_when_still_no_ticketing_date():
    concert_id = uuid.uuid4()
    fake_url = "https://s3.example.com/crawls/updated.png"
    mock_concert = MagicMock()
    mock_concert.crawl_attempt_count = 0
    mock_concert.id = concert_id
    mock_concert.name = "공연명"
    mock_concert.crawl_screenshot_url = "https://s3.example.com/crawls/placeholder.png"
    mock_concert.ticketing_date = None
    mock_concert.end_date = None
    mock_concert.crawl_attempted_at = datetime.now(timezone.utc) - timedelta(hours=25)  # 쿨다운(24h) 지남

    mock_db = AsyncMock()
    mock_db.execute = AsyncMock(return_value=MagicMock(scalar_one_or_none=MagicMock(return_value=mock_concert)))
    mock_db.commit = AsyncMock()
    mock_db.__aenter__ = AsyncMock(return_value=mock_db)
    mock_db.__aexit__ = AsyncMock(return_value=None)

    mock_crawler = AsyncMock(return_value=b"bytes")
    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch.dict("app.services.crawler._CRAWLERS", {"INTERPARK": mock_crawler}),
        patch("app.services.crawler._upload_screenshot", new=AsyncMock(return_value=fake_url)),
    ):
        await crawl_and_save(concert_id, "INTERPARK")

    mock_crawler.assert_awaited_once()
    assert mock_concert.crawl_screenshot_url == fake_url


# 누적 시도 횟수가 상한(_MAX_CRAWL_ATTEMPTS)에 도달하면, 쿨다운이 지났어도 더 이상 재시도하지
# 않고 포기하는지 테스트 (영구 실패 공연에 축제 기간 내내 매일 재시도하며 낭비되던 버그 회귀 방지)
@pytest.mark.asyncio
async def test_crawl_and_save_gives_up_after_max_attempts():
    from app.services.crawler import _MAX_CRAWL_ATTEMPTS

    concert_id = uuid.uuid4()
    mock_concert = MagicMock()
    mock_concert.id = concert_id
    mock_concert.name = "공연명"
    mock_concert.ticketing_date = None
    mock_concert.end_date = None
    mock_concert.crawl_attempted_at = datetime.now(timezone.utc) - timedelta(hours=25)  # 쿨다운 지남
    mock_concert.crawl_attempt_count = _MAX_CRAWL_ATTEMPTS  # 이미 상한 도달

    mock_db = AsyncMock()
    mock_db.execute = AsyncMock(return_value=MagicMock(scalar_one_or_none=MagicMock(return_value=mock_concert)))
    mock_db.commit = AsyncMock()
    mock_db.__aenter__ = AsyncMock(return_value=mock_db)
    mock_db.__aexit__ = AsyncMock(return_value=None)

    mock_crawler = AsyncMock(return_value=b"bytes")
    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch.dict("app.services.crawler._CRAWLERS", {"INTERPARK": mock_crawler}),
    ):
        await crawl_and_save(concert_id, "INTERPARK")

    mock_crawler.assert_not_called()
    mock_db.commit.assert_not_awaited()


# 크롤링 결과 None이면 S3 업로드 없이 종료
@pytest.mark.asyncio
async def test_crawl_and_save_crawler_returns_none_skips_upload():
    concert_id = uuid.uuid4()
    mock_concert = MagicMock()
    mock_concert.crawl_attempt_count = 0
    mock_concert.id = concert_id
    mock_concert.name = "공연명"
    mock_concert.crawl_screenshot_url = None
    mock_concert.ticketing_date = None
    mock_concert.end_date = None
    mock_concert.crawl_attempted_at = None

    mock_db = AsyncMock()
    mock_db.execute = AsyncMock(return_value=MagicMock(scalar_one_or_none=MagicMock(return_value=mock_concert)))
    mock_db.commit = AsyncMock()
    mock_db.__aenter__ = AsyncMock(return_value=mock_db)
    mock_db.__aexit__ = AsyncMock(return_value=None)

    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch.dict("app.services.crawler._CRAWLERS", {"INTERPARK": AsyncMock(return_value=None)}),
        patch("app.services.crawler._upload_screenshot") as mock_upload,
    ):
        await crawl_and_save(concert_id, "INTERPARK")

    mock_upload.assert_not_called()
    # crawl_attempted_at 기록용 commit은 있었지만 스크린샷 업로드는 없었으므로 crawl_screenshot_url용 commit은 없음
    assert mock_db.commit.await_count == 1


# crawl_melon 테스트

def _make_melon_pw_mock(
    screenshot: bytes,
    current_url: str = "https://ticket.melon.com/search",
    link_href: str | None = None,
    img_srcs: list[str] | None = None,
    body_text: str = "정상적으로 로딩된 공연 상세 페이지 콘텐츠입니다",
):
    """멜론 mock: page.url 속성 지원 포함"""
    mock_link = None
    if link_href:
        mock_link = AsyncMock()
        mock_link.get_attribute = AsyncMock(return_value=link_href)

    mock_page = AsyncMock()
    mock_page.goto = AsyncMock()
    mock_page.wait_for_timeout = AsyncMock()
    mock_page.query_selector = AsyncMock(return_value=mock_link)
    mock_page.screenshot = AsyncMock(return_value=screenshot)
    mock_page.inner_text = AsyncMock(return_value=body_text)
    mock_page.eval_on_selector_all = AsyncMock(return_value=img_srcs or [])
    type(mock_page).url = current_url

    mock_context = AsyncMock()
    mock_context.new_page = AsyncMock(return_value=mock_page)

    mock_browser = AsyncMock()
    mock_browser.new_context = AsyncMock(return_value=mock_context)
    mock_browser.close = AsyncMock()

    mock_pw = AsyncMock()
    mock_pw.chromium.launch = AsyncMock(return_value=mock_browser)

    mock_cm = AsyncMock()
    mock_cm.__aenter__ = AsyncMock(return_value=mock_pw)
    mock_cm.__aexit__ = AsyncMock(return_value=None)
    return mock_cm


# 정상 검색 결과 스크린샷 반환
@pytest.mark.asyncio
async def test_crawl_melon_search_page_screenshot(mock_concert):
    expected = b"melon-png"
    with patch("app.services.crawler.async_playwright", return_value=_make_melon_pw_mock(expected)):
        result = await crawl_melon(mock_concert)
    assert result == expected


# Kakao 리다이렉트 감지 시 None 반환 (graceful skip)
@pytest.mark.asyncio
async def test_crawl_melon_returns_none_on_kakao_redirect(mock_concert):
    kakao_url = "https://accounts.kakao.com/login"
    with patch("app.services.crawler.async_playwright", return_value=_make_melon_pw_mock(b"", current_url=kakao_url)):
        result = await crawl_melon(mock_concert)
    assert result is None


# Playwright 예외 시 None 반환
@pytest.mark.asyncio
async def test_crawl_melon_returns_none_on_error(mock_concert):
    mock_cm = AsyncMock()
    mock_cm.__aenter__ = AsyncMock(side_effect=Exception("bot block"))
    mock_cm.__aexit__ = AsyncMock(return_value=None)
    with patch("app.services.crawler.async_playwright", return_value=mock_cm):
        result = await crawl_melon(mock_concert)
    assert result is None


# crawl_and_save - TICKETLINK → KOPIS 폴백 확인
@pytest.mark.asyncio
async def test_crawl_and_save_ticketlink_falls_back_to_kopis():
    concert_id = uuid.uuid4()
    fake_url = "https://s3.example.com/crawls/kopis.png"

    mock_concert = MagicMock()
    mock_concert.crawl_attempt_count = 0
    mock_concert.id = concert_id
    mock_concert.name = "공연명"
    mock_concert.kopis_id = "PF291361"
    mock_concert.ticketing_links = None
    mock_concert.crawl_screenshot_url = None
    mock_concert.ticketing_date = None
    mock_concert.end_date = None
    mock_concert.crawl_attempted_at = None

    mock_db = AsyncMock()
    mock_db.execute = AsyncMock(return_value=MagicMock(scalar_one_or_none=MagicMock(return_value=mock_concert)))
    mock_db.commit = AsyncMock()
    mock_db.__aenter__ = AsyncMock(return_value=mock_db)
    mock_db.__aexit__ = AsyncMock(return_value=None)

    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch("app.services.crawler.crawl_kopis", new=AsyncMock(return_value=b"kopis-bytes")),
        patch("app.services.crawler._upload_screenshot", new=AsyncMock(return_value=fake_url)),
    ):
        await crawl_and_save(concert_id, "TICKETLINK")

    assert mock_concert.crawl_screenshot_url == fake_url


# crawl_and_save - TICKETLINK + kopis_id 없으면 업로드 없이 종료
@pytest.mark.asyncio
async def test_crawl_and_save_ticketlink_no_kopis_id_skips():
    concert_id = uuid.uuid4()

    mock_concert = MagicMock()
    mock_concert.crawl_attempt_count = 0
    mock_concert.id = concert_id
    mock_concert.name = "공연명"
    mock_concert.kopis_id = None
    mock_concert.ticketing_links = None
    mock_concert.crawl_screenshot_url = None
    mock_concert.ticketing_date = None
    mock_concert.end_date = None
    mock_concert.crawl_attempted_at = None

    mock_db = AsyncMock()
    mock_db.execute = AsyncMock(return_value=MagicMock(scalar_one_or_none=MagicMock(return_value=mock_concert)))
    mock_db.commit = AsyncMock()
    mock_db.__aenter__ = AsyncMock(return_value=mock_db)
    mock_db.__aexit__ = AsyncMock(return_value=None)

    mock_upload = AsyncMock()
    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch("app.services.crawler._upload_screenshot", new=mock_upload),
    ):
        await crawl_and_save(concert_id, "TICKETLINK")

    mock_upload.assert_not_called()


# 멜론 봇 차단(None 반환) 시 S3 업로드 없이 종료
@pytest.mark.asyncio
async def test_crawl_and_save_melon_bot_block_skips():
    concert_id = uuid.uuid4()
    mock_concert = MagicMock()
    mock_concert.crawl_attempt_count = 0
    mock_concert.id = concert_id
    mock_concert.name = "공연명"
    mock_concert.crawl_screenshot_url = None
    mock_concert.ticketing_date = None
    mock_concert.end_date = None
    mock_concert.crawl_attempted_at = None

    mock_db = AsyncMock()
    mock_db.execute = AsyncMock(return_value=MagicMock(scalar_one_or_none=MagicMock(return_value=mock_concert)))
    mock_db.commit = AsyncMock()
    mock_db.__aenter__ = AsyncMock(return_value=mock_db)
    mock_db.__aexit__ = AsyncMock(return_value=None)

    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch.dict("app.services.crawler._CRAWLERS", {"MELON": AsyncMock(return_value=None)}),
        patch("app.services.crawler._upload_screenshot") as mock_upload,
    ):
        await crawl_and_save(concert_id, "MELON")

    mock_upload.assert_not_called()
    assert mock_db.commit.await_count == 1


# retry_pending_crawls 테스트

# 찜한 유저가 아무도 없으면 아무것도 안 함
@pytest.mark.asyncio
async def test_retry_pending_crawls_no_follows_does_nothing():
    mock_db = AsyncMock()
    mock_db.execute = AsyncMock(
        return_value=MagicMock(scalars=MagicMock(return_value=MagicMock(all=MagicMock(return_value=[]))))
    )
    mock_db.__aenter__ = AsyncMock(return_value=mock_db)
    mock_db.__aexit__ = AsyncMock(return_value=None)

    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch("app.services.crawler.crawl_and_save", new=AsyncMock()) as mock_crawl,
    ):
        await retry_pending_crawls()

    mock_crawl.assert_not_called()


# 찜된 공연 중 ticketing_date를 아직 못 얻고 안 끝난 것만 crawl_and_save 재호출 대상이 되는지 테스트
@pytest.mark.asyncio
async def test_retry_pending_crawls_calls_crawl_and_save_for_pending_concerts():
    concert_id = uuid.uuid4()

    mock_follow = MagicMock()
    mock_follow.concerts = [{"concert_id": str(concert_id)}]

    follows_result = MagicMock(scalars=MagicMock(return_value=MagicMock(all=MagicMock(return_value=[mock_follow]))))
    concerts_result = MagicMock(all=MagicMock(return_value=[(concert_id,)]))

    mock_db = AsyncMock()
    mock_db.execute = AsyncMock(side_effect=[follows_result, concerts_result])
    mock_db.__aenter__ = AsyncMock(return_value=mock_db)
    mock_db.__aexit__ = AsyncMock(return_value=None)

    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch("app.services.crawler.crawl_and_save", new=AsyncMock()) as mock_crawl,
    ):
        await retry_pending_crawls()

    mock_crawl.assert_awaited_once_with(concert_id)


# 재시도 대상이 여러 건이어도 동시 실행 개수가 상한(_RETRY_CRAWL_CONCURRENCY)을 넘지 않는지,
# 그리고 전부 처리되는지 테스트 (완전 순차 처리로 배치가 오래 걸리던 문제의 병렬화 회귀 방지)
@pytest.mark.asyncio
async def test_retry_pending_crawls_bounds_concurrency():
    from app.services.crawler import _RETRY_CRAWL_CONCURRENCY

    concert_ids = [uuid.uuid4() for _ in range(_RETRY_CRAWL_CONCURRENCY * 3)]
    mock_follow = MagicMock()
    mock_follow.concerts = [{"concert_id": str(cid)} for cid in concert_ids]

    follows_result = MagicMock(scalars=MagicMock(return_value=MagicMock(all=MagicMock(return_value=[mock_follow]))))
    concerts_result = MagicMock(all=MagicMock(return_value=[(cid,) for cid in concert_ids]))

    mock_db = AsyncMock()
    mock_db.execute = AsyncMock(side_effect=[follows_result, concerts_result])
    mock_db.__aenter__ = AsyncMock(return_value=mock_db)
    mock_db.__aexit__ = AsyncMock(return_value=None)

    in_flight = 0
    max_in_flight = 0

    async def _fake_crawl(concert_id):
        nonlocal in_flight, max_in_flight
        in_flight += 1
        max_in_flight = max(max_in_flight, in_flight)
        await asyncio.sleep(0.01)
        in_flight -= 1

    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch("app.services.crawler.crawl_and_save", new=AsyncMock(side_effect=_fake_crawl)) as mock_crawl,
    ):
        await retry_pending_crawls()

    assert mock_crawl.await_count == len(concert_ids)
    assert max_in_flight == _RETRY_CRAWL_CONCURRENCY


# send_screenshots_to_llm 테스트

# LLM_CRAWL_URL 미설정 시 전송 없이 종료
@pytest.mark.asyncio
async def test_send_screenshots_skips_when_url_not_configured():
    with (
        patch("app.services.crawler.settings") as mock_settings,
        patch("app.services.crawler.AsyncSessionLocal") as mock_session,
    ):
        mock_settings.LLM_CRAWL_URL = ""
        await send_screenshots_to_llm()
    mock_session.assert_not_called()


# 스크린샷 있는 공연 목록을 LLM팀 URL로 POST
@pytest.mark.asyncio
async def test_send_screenshots_posts_to_llm():
    import datetime

    concert = MagicMock()
    concert.id = uuid.uuid4()
    concert.name = "테스트"
    concert.crawl_screenshot_url = "https://s3.example.com/shot.png"

    mock_db = AsyncMock()
    mock_db.execute = AsyncMock(return_value=MagicMock(scalars=MagicMock(return_value=MagicMock(all=MagicMock(return_value=[concert])))))
    mock_db.__aenter__ = AsyncMock(return_value=mock_db)
    mock_db.__aexit__ = AsyncMock(return_value=None)

    mock_response = MagicMock()
    mock_response.raise_for_status = MagicMock()
    mock_http = AsyncMock()
    mock_http.post = AsyncMock(return_value=mock_response)
    mock_http.__aenter__ = AsyncMock(return_value=mock_http)
    mock_http.__aexit__ = AsyncMock(return_value=None)

    with (
        patch("app.services.crawler.settings") as mock_settings,
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch("app.services.crawler.httpx.AsyncClient", return_value=mock_http),
    ):
        mock_settings.LLM_CRAWL_URL = "https://llm.example.com/crawl"
        mock_settings.LLM_EXTRACT_API_KEY = "test-key"
        await send_screenshots_to_llm()

    mock_http.post.assert_awaited_once()
    call_args = mock_http.post.call_args
    assert call_args[0][0] == "https://llm.example.com/crawl"
    payload = call_args[1]["json"]
    assert len(payload) == 1
    assert payload[0]["concert_name"] == "테스트"


# 라인업 변경 감지 정규화 테스트

def test_normalize_lineup_img_srcs_filters_ads_and_ignores_query_strings():
    from app.services.crawler import _normalize_lineup_img_srcs

    srcs = [
        "https://img.example.com/poster.jpg?t=1",
        "https://img.example.com/poster.jpg?t=2",  # 쿼리스트링만 다름 - 같은 이미지로 취급
        "https://ad.doubleclick.net/banner.png",
        "",
    ]
    assert _normalize_lineup_img_srcs(srcs) == ["https://img.example.com/poster.jpg"]


def test_hash_lineup_text_ignores_digit_noise():
    from app.services.crawler import _hash_lineup_text

    assert _hash_lineup_text("좋아요 123개") == _hash_lineup_text("좋아요 456개")
    assert _hash_lineup_text("라인업: 가수A") != _hash_lineup_text("라인업: 가수B")


# 인터파크 "캐스팅" 섹션의 "{아티스트명} 더 알아보기" 한 줄이 방문마다 로테이션되는 실측 노이즈를
# 무시하는지 테스트 (실제 라인업 목록 자체는 동일한데 이 줄만 달랐던 실측 사례, 2026-07-29)
def test_hash_lineup_text_ignores_rotating_learn_more_line():
    from app.services.crawler import _hash_lineup_text

    text_a = "캐스팅\n\n루시 더 알아보기\n\n09.19(토)\n김수영\n09.19(토)\n루시"
    text_b = "캐스팅\n\n김수영 더 알아보기\n\n09.19(토)\n김수영\n09.19(토)\n루시"
    assert _hash_lineup_text(text_a) == _hash_lineup_text(text_b)


# container_selector 스코핑 테스트 - 인터파크 상단 회전 광고 배너가 body 전체 캡처에 섞여
# 들어가 라인업이 안 바뀌어도 "변경"으로 오탐시켰던 걸 실데이터로 확인함(2026-09-02).
# .productMain 안쪽만 캡처하면 배너가 원천적으로 제외됨.

@pytest.mark.asyncio
async def test_capture_lineup_snapshot_scopes_to_container_when_present():
    from app.services.crawler import _capture_lineup_snapshot

    mock_locator = AsyncMock()
    mock_locator.count = AsyncMock(return_value=1)

    mock_page = AsyncMock()
    mock_page.locator = MagicMock(return_value=mock_locator)
    mock_page.inner_text = AsyncMock(return_value="컨테이너 안쪽 텍스트")
    mock_page.eval_on_selector_all = AsyncMock(return_value=["https://img.example.com/a.jpg"])

    text, _text_hash, img_srcs = await _capture_lineup_snapshot(mock_page, container_selector=".productMain")

    mock_page.locator.assert_called_once_with(".productMain")
    mock_page.inner_text.assert_awaited_once_with(".productMain")
    mock_page.eval_on_selector_all.assert_awaited_once_with(".productMain img", "els => els.map(e => e.src)")
    assert text == "컨테이너 안쪽 텍스트"
    assert img_srcs == ["https://img.example.com/a.jpg"]


@pytest.mark.asyncio
async def test_capture_lineup_snapshot_falls_back_to_body_when_container_missing():
    from app.services.crawler import _capture_lineup_snapshot

    mock_locator = AsyncMock()
    mock_locator.count = AsyncMock(return_value=0)  # 페이지에 해당 셀렉터가 없음 (구조 변경 등)

    mock_page = AsyncMock()
    mock_page.locator = MagicMock(return_value=mock_locator)
    mock_page.inner_text = AsyncMock(return_value="body 전체 텍스트")
    mock_page.eval_on_selector_all = AsyncMock(return_value=[])

    text, _text_hash, _img_srcs = await _capture_lineup_snapshot(mock_page, container_selector=".doesNotExist")

    mock_page.inner_text.assert_awaited_once_with("body")
    mock_page.eval_on_selector_all.assert_awaited_once_with("img", "els => els.map(e => e.src)")
    assert text == "body 전체 텍스트"


@pytest.mark.asyncio
async def test_capture_lineup_snapshot_falls_back_to_body_on_locator_error():
    from app.services.crawler import _capture_lineup_snapshot

    mock_page = AsyncMock()
    mock_page.locator = MagicMock(side_effect=Exception("locator 조회 실패"))
    mock_page.inner_text = AsyncMock(return_value="body 전체 텍스트")
    mock_page.eval_on_selector_all = AsyncMock(return_value=[])

    text, _text_hash, _img_srcs = await _capture_lineup_snapshot(mock_page, container_selector=".broken")

    mock_page.inner_text.assert_awaited_once_with("body")
    assert text == "body 전체 텍스트"


@pytest.mark.asyncio
async def test_capture_lineup_snapshot_without_container_selector_uses_body():
    from app.services.crawler import _capture_lineup_snapshot

    mock_page = AsyncMock()
    mock_page.inner_text = AsyncMock(return_value="body 전체 텍스트")
    mock_page.eval_on_selector_all = AsyncMock(return_value=[])

    text, _text_hash, _img_srcs = await _capture_lineup_snapshot(mock_page)

    mock_page.locator.assert_not_called()
    mock_page.inner_text.assert_awaited_once_with("body")
    assert text == "body 전체 텍스트"


# capture_lineup_snapshot=True 시 (screenshot, text_hash, img_srcs) 튜플 반환 테스트

@pytest.mark.asyncio
async def test_crawl_interpark_capture_lineup_snapshot_returns_tuple(mock_concert):
    expected_screenshot = b"interpark-direct-png"
    pw_mock = _make_pw_mock(
        expected_screenshot, body_text="라인업 텍스트 - 아티스트A, 아티스트B 출연 예정입니다", img_srcs=["https://img.example.com/poster.jpg"]
    )
    with patch("app.services.crawler.async_playwright", return_value=pw_mock):
        result = await crawl_interpark(
            mock_concert, direct_url="https://tickets.interpark.com/goods/12345", capture_lineup_snapshot=True
        )
    screenshot, _text, text_hash, img_srcs = result
    assert screenshot == expected_screenshot
    assert isinstance(text_hash, str) and text_hash
    assert img_srcs == ["https://img.example.com/poster.jpg"]


@pytest.mark.asyncio
async def test_crawl_yes24_capture_lineup_snapshot_returns_tuple(mock_concert):
    expected_screenshot = b"yes24-png"
    pw_mock = _make_pw_mock(
        expected_screenshot, body_text="라인업 텍스트 - 아티스트A, 아티스트B 출연 예정입니다", img_srcs=["https://img.example.com/poster.jpg"]
    )
    with patch("app.services.crawler.async_playwright", return_value=pw_mock):
        result = await crawl_yes24(mock_concert, capture_lineup_snapshot=True)
    screenshot, _text, text_hash, img_srcs = result
    assert screenshot == expected_screenshot
    assert isinstance(text_hash, str) and text_hash
    assert img_srcs == ["https://img.example.com/poster.jpg"]


@pytest.mark.asyncio
async def test_crawl_melon_capture_lineup_snapshot_returns_tuple(mock_concert):
    expected_screenshot = b"melon-png"
    pw_mock = _make_melon_pw_mock(expected_screenshot, img_srcs=["https://img.example.com/poster.jpg"])
    with patch("app.services.crawler.async_playwright", return_value=pw_mock):
        result = await crawl_melon(mock_concert, capture_lineup_snapshot=True)
    screenshot, _text, text_hash, img_srcs = result
    assert screenshot == expected_screenshot
    assert isinstance(text_hash, str) and text_hash
    assert img_srcs == ["https://img.example.com/poster.jpg"]


@pytest.mark.asyncio
async def test_crawl_kopis_capture_lineup_snapshot_returns_tuple(mock_concert):
    mock_concert.kopis_id = "PF123456"
    expected_screenshot = b"kopis-png"
    pw_mock = _make_pw_mock(
        expected_screenshot, body_text="공연안내 - 아티스트A, 아티스트B 출연", img_srcs=["https://img.example.com/poster.jpg"]
    )
    with patch("app.services.crawler.async_playwright", return_value=pw_mock):
        result = await crawl_kopis(mock_concert, capture_lineup_snapshot=True)
    screenshot, _text, text_hash, img_srcs = result
    assert screenshot == expected_screenshot
    assert isinstance(text_hash, str) and text_hash
    assert img_srcs == ["https://img.example.com/poster.jpg"]


# kopis_id가 없으면 브라우저를 띄우지도 않고 바로 None 반환하는지 테스트
@pytest.mark.asyncio
async def test_crawl_kopis_no_kopis_id_returns_none(mock_concert):
    mock_concert.kopis_id = None
    with patch("app.services.crawler.async_playwright") as mock_pw_ctor:
        result = await crawl_kopis(mock_concert)
    assert result is None
    mock_pw_ctor.assert_not_called()


# _check_festival_lineup 테스트

def _make_festival_concert(concert_id, **overrides):
    concert = MagicMock()
    concert.id = concert_id
    concert.name = "테스트 페스티벌"
    concert.end_date = None
    concert.ticketing_links = {"INTERPARK": "https://tickets.interpark.com/goods/1"}
    concert.lineup_check_attempted_at = None
    concert.lineup_snapshot_hash = None
    concert.lineup_snapshot_img_srcs = None
    for key, value in overrides.items():
        setattr(concert, key, value)
    return concert


def _make_db_mock(concert):
    mock_db = AsyncMock()
    mock_db.execute = AsyncMock(return_value=MagicMock(scalar_one_or_none=MagicMock(return_value=concert)))
    mock_db.commit = AsyncMock()
    mock_db.__aenter__ = AsyncMock(return_value=mock_db)
    mock_db.__aexit__ = AsyncMock(return_value=None)
    return mock_db


# 최초 방문(직전 스냅샷 없음)이면 무조건 스크린샷을 업로드하고 스냅샷을 저장하는지 테스트
@pytest.mark.asyncio
async def test_check_festival_lineup_first_visit_uploads_and_saves_snapshot():
    from app.services.crawler import _check_festival_lineup

    concert_id = uuid.uuid4()
    concert = _make_festival_concert(concert_id)
    mock_db = _make_db_mock(concert)

    mock_crawler = AsyncMock(return_value=(b"png", "raw text a", "hash-a", ["https://img.example.com/a.jpg"]))
    fake_url = "https://s3.example.com/crawls/versioned.png"

    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch.dict("app.services.crawler._CRAWLERS", {"INTERPARK": mock_crawler}),
        patch("app.services.crawler._upload_screenshot", new=AsyncMock(return_value=fake_url)),
        patch("app.services.crawler.refresh_ticketing_links", new=AsyncMock(return_value=False)),
    ):
        await _check_festival_lineup(concert_id)

    assert mock_crawler.call_args.kwargs["capture_lineup_snapshot"] is True
    assert concert.crawl_screenshot_url == fake_url
    assert concert.lineup_snapshot_hash == "hash-a"
    assert concert.lineup_snapshot_img_srcs == ["https://img.example.com/a.jpg"]


# 직전과 스냅샷이 동일하면(라인업 안 바뀜) 업로드 없이 스킵하는지 테스트
@pytest.mark.asyncio
async def test_check_festival_lineup_unchanged_skips_upload():
    from app.services.crawler import _check_festival_lineup

    concert_id = uuid.uuid4()
    concert = _make_festival_concert(
        concert_id,
        lineup_snapshot_hash="hash-a",
        lineup_snapshot_img_srcs=["https://img.example.com/a.jpg"],
        crawl_screenshot_url="https://s3.example.com/crawls/old.png",
    )
    mock_db = _make_db_mock(concert)

    mock_crawler = AsyncMock(return_value=(b"png", "raw text a", "hash-a", ["https://img.example.com/a.jpg"]))
    mock_upload = AsyncMock()

    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch.dict("app.services.crawler._CRAWLERS", {"INTERPARK": mock_crawler}),
        patch("app.services.crawler._upload_screenshot", new=mock_upload),
        patch("app.services.crawler.refresh_ticketing_links", new=AsyncMock(return_value=False)),
    ):
        await _check_festival_lineup(concert_id)

    mock_upload.assert_not_called()
    assert concert.crawl_screenshot_url == "https://s3.example.com/crawls/old.png"


# 직전과 스냅샷이 다르면(라인업 바뀜) 새 버전 키로 업로드하고 스냅샷을 갱신하는지 테스트
@pytest.mark.asyncio
async def test_check_festival_lineup_changed_uploads_new_version():
    from app.services.crawler import _check_festival_lineup

    concert_id = uuid.uuid4()
    concert = _make_festival_concert(
        concert_id,
        lineup_snapshot_hash="hash-a",
        lineup_snapshot_img_srcs=["https://img.example.com/a.jpg"],
    )
    mock_db = _make_db_mock(concert)

    mock_crawler = AsyncMock(return_value=(b"png", "raw text b", "hash-b", ["https://img.example.com/b.jpg"]))
    fake_url = "https://s3.example.com/crawls/new-version.png"

    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch.dict("app.services.crawler._CRAWLERS", {"INTERPARK": mock_crawler}),
        patch("app.services.crawler._upload_screenshot", new=AsyncMock(return_value=fake_url)),
        patch("app.services.crawler.refresh_ticketing_links", new=AsyncMock(return_value=False)),
    ):
        await _check_festival_lineup(concert_id)

    assert concert.crawl_screenshot_url == fake_url
    assert concert.lineup_snapshot_hash == "hash-b"
    assert concert.lineup_snapshot_img_srcs == ["https://img.example.com/b.jpg"]


# 쿨다운 이내면 크롤러 호출 없이 종료하는지 테스트
@pytest.mark.asyncio
async def test_check_festival_lineup_skips_within_cooldown():
    from app.services.crawler import _check_festival_lineup

    concert_id = uuid.uuid4()
    concert = _make_festival_concert(
        concert_id, lineup_check_attempted_at=datetime.now(timezone.utc) - timedelta(hours=1)
    )
    mock_db = _make_db_mock(concert)

    mock_crawler = AsyncMock()
    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch.dict("app.services.crawler._CRAWLERS", {"INTERPARK": mock_crawler}),
    ):
        await _check_festival_lineup(concert_id)

    mock_crawler.assert_not_called()


# 크롤링 대상 사이트를 못 고르면(ticketing_links 없음, 예: 티켓링크 전용) crawl_and_save와
# 동일하게 KOPIS 상세페이지로 폴백하는지 테스트
@pytest.mark.asyncio
async def test_check_festival_lineup_falls_back_to_kopis_when_no_site_resolvable():
    from app.services.crawler import _check_festival_lineup

    concert_id = uuid.uuid4()
    concert = _make_festival_concert(concert_id, ticketing_links=None, kopis_id="PF123456")
    mock_db = _make_db_mock(concert)

    mock_kopis_crawler = AsyncMock(return_value=(b"kopis-png", "raw text", "hash-kopis", []))
    fake_url = "https://s3.example.com/crawls/kopis-versioned.png"

    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch("app.services.crawler.crawl_kopis", new=mock_kopis_crawler),
        patch("app.services.crawler._upload_screenshot", new=AsyncMock(return_value=fake_url)),
        patch("app.services.crawler.refresh_ticketing_links", new=AsyncMock(return_value=False)),
    ):
        await _check_festival_lineup(concert_id)

    mock_kopis_crawler.assert_awaited_once_with(concert, capture_lineup_snapshot=True)
    assert concert.crawl_screenshot_url == fake_url
    assert concert.lineup_snapshot_hash == "hash-kopis"


# KOPIS 폴백도 실패(kopis_id 없음 등)하면 업로드 없이 종료하는지 테스트
@pytest.mark.asyncio
async def test_check_festival_lineup_skips_when_kopis_fallback_also_fails():
    from app.services.crawler import _check_festival_lineup

    concert_id = uuid.uuid4()
    concert = _make_festival_concert(concert_id, ticketing_links=None, kopis_id=None)
    mock_db = _make_db_mock(concert)

    mock_upload = AsyncMock()
    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch("app.services.crawler._upload_screenshot", new=mock_upload),
        patch("app.services.crawler.refresh_ticketing_links", new=AsyncMock(return_value=False)),
    ):
        await _check_festival_lineup(concert_id)

    mock_upload.assert_not_called()


# refresh_ticketing_links가 갱신한 새 링크로 크롤링 대상을 고르는지 테스트 - 얼리버드/블라인드
# 판매 시점에 캡처된 예매 링크가 실제 판매 링크로 바뀌었을 때, 그 갱신된 값을 바로 사용해야 함
@pytest.mark.asyncio
async def test_check_festival_lineup_uses_refreshed_ticketing_link():
    from app.services.crawler import _check_festival_lineup

    concert_id = uuid.uuid4()
    concert = _make_festival_concert(
        concert_id, ticketing_links={"INTERPARK": "https://tickets.interpark.com/goods/OLD_BLIND"}
    )
    mock_db = _make_db_mock(concert)

    async def _refresh(c):
        c.ticketing_links = {"INTERPARK": "https://tickets.interpark.com/goods/NEW_REAL"}
        return True

    mock_crawler = AsyncMock(return_value=(b"png", "raw text", "hash", []))
    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch.dict("app.services.crawler._CRAWLERS", {"INTERPARK": mock_crawler}),
        patch("app.services.crawler._upload_screenshot", new=AsyncMock(return_value="https://s3.example.com/x.png")),
        patch("app.services.crawler.refresh_ticketing_links", new=_refresh),
    ):
        await _check_festival_lineup(concert_id)

    assert mock_crawler.call_args.kwargs["direct_url"] == "https://tickets.interpark.com/goods/NEW_REAL"


# 공연이 이미 끝났으면 크롤러 호출 없이 종료하는지 테스트
@pytest.mark.asyncio
async def test_check_festival_lineup_skips_when_concert_ended():
    from app.services.crawler import _check_festival_lineup

    concert_id = uuid.uuid4()
    concert = _make_festival_concert(concert_id, end_date=datetime(2020, 1, 1, tzinfo=timezone.utc))
    mock_db = _make_db_mock(concert)

    mock_crawler = AsyncMock()
    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch.dict("app.services.crawler._CRAWLERS", {"INTERPARK": mock_crawler}),
    ):
        await _check_festival_lineup(concert_id)

    mock_crawler.assert_not_called()


# _check_festival_lineup_limited 테스트

# 개별 크롤이 타임아웃을 넘겨도 예외가 밖으로 안 새고, semaphore도 정상 반환되는지 테스트
# (gather() 전체가 하루 넘게 안 끝나던 실제 장애 대응)
@pytest.mark.asyncio
async def test_check_festival_lineup_limited_timeout_does_not_propagate():
    from app.services.crawler import _check_festival_lineup_limited

    concert_id = uuid.uuid4()

    async def _hang(_concert_id):
        await asyncio.sleep(10)

    with (
        patch("app.services.crawler._check_festival_lineup", new=_hang),
        patch("app.services.crawler._FESTIVAL_LINEUP_CHECK_TIMEOUT", 0.05),
    ):
        semaphore = asyncio.Semaphore(1)
        await _check_festival_lineup_limited(semaphore, concert_id)  # 예외 없이 반환돼야 함

    # 타임아웃 후에도 semaphore가 반환돼 다음 작업이 즉시 진행 가능한지 확인
    assert semaphore.locked() is False


# retry_festival_lineup_checks 테스트

# event_type=FESTIVAL 대상만 _check_festival_lineup 호출로 이어지는지 테스트
@pytest.mark.asyncio
async def test_retry_festival_lineup_checks_calls_check_for_each_target():
    from app.services.crawler import retry_festival_lineup_checks

    concert_id = uuid.uuid4()
    concerts_result = MagicMock(all=MagicMock(return_value=[(concert_id,)]))

    mock_db = AsyncMock()
    mock_db.execute = AsyncMock(return_value=concerts_result)
    mock_db.__aenter__ = AsyncMock(return_value=mock_db)
    mock_db.__aexit__ = AsyncMock(return_value=None)

    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch("app.services.crawler._check_festival_lineup", new=AsyncMock()) as mock_check,
    ):
        await retry_festival_lineup_checks()

    mock_check.assert_awaited_once_with(concert_id)


# 대상이 없으면 아무것도 안 하는지 테스트
@pytest.mark.asyncio
async def test_retry_festival_lineup_checks_no_targets_does_nothing():
    from app.services.crawler import retry_festival_lineup_checks

    concerts_result = MagicMock(all=MagicMock(return_value=[]))
    mock_db = AsyncMock()
    mock_db.execute = AsyncMock(return_value=concerts_result)
    mock_db.__aenter__ = AsyncMock(return_value=mock_db)
    mock_db.__aexit__ = AsyncMock(return_value=None)

    with (
        patch("app.services.crawler.AsyncSessionLocal", return_value=mock_db),
        patch("app.services.crawler._check_festival_lineup", new=AsyncMock()) as mock_check,
    ):
        await retry_festival_lineup_checks()

    mock_check.assert_not_called()
