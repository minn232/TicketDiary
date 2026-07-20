import uuid
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from app.services.crawler import (
    _pick_crawl_target,
    crawl_and_save,
    crawl_interpark,
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


def _make_pw_mock(screenshot: bytes, link_href: str | None = None, body_text: str = ""):
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
    mock_detail_page = AsyncMock()
    mock_detail_page.wait_for_load_state = AsyncMock()
    mock_detail_page.wait_for_timeout = AsyncMock()
    mock_detail_page.screenshot = AsyncMock(return_value=detail_screenshot or screenshot)

    mock_locator = AsyncMock()
    mock_locator.count = AsyncMock(return_value=card_count)
    mock_locator.click = AsyncMock()
    mock_locator.first = mock_locator

    mock_browser_context = MagicMock()
    mock_browser_context.expect_page = MagicMock(return_value=_FakeExpectPageCM(mock_detail_page))

    mock_page = AsyncMock()
    mock_page.goto = AsyncMock()
    mock_page.wait_for_timeout = AsyncMock()
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
    pw_mock = _make_pw_mock(expected, body_text="R석 110,000원 예매하기")
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


# crawl_and_save 테스트

# NOL ticket으로 등록된 티켓도 INTERPARK 크롤러로 처리되는지 확인
@pytest.mark.asyncio
async def test_crawl_and_save_nol_ticket_uses_interpark_crawler():
    concert_id = uuid.uuid4()
    fake_url = "https://s3.example.com/crawls/screenshot.png"

    mock_concert = MagicMock()
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


# 크롤링 결과 None이면 S3 업로드 없이 종료
@pytest.mark.asyncio
async def test_crawl_and_save_crawler_returns_none_skips_upload():
    concert_id = uuid.uuid4()
    mock_concert = MagicMock()
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

def _make_melon_pw_mock(screenshot: bytes, current_url: str = "https://ticket.melon.com/search", link_href: str | None = None):
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
