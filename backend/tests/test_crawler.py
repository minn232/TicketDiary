import uuid
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from app.services.crawler import (
    crawl_and_save,
    crawl_interpark,
    crawl_yes24,
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


def _make_pw_mock(screenshot: bytes, link_href: str | None = None):
    mock_link = None
    if link_href:
        mock_link = AsyncMock()
        mock_link.get_attribute = AsyncMock(return_value=link_href)

    mock_page = AsyncMock()
    mock_page.goto = AsyncMock()
    mock_page.wait_for_timeout = AsyncMock()
    mock_page.query_selector = AsyncMock(return_value=mock_link)
    mock_page.screenshot = AsyncMock(return_value=screenshot)

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


# crawl_interpark 테스트

# 링크 없어도 검색 결과 페이지 스크린샷 반환
@pytest.mark.asyncio
async def test_crawl_interpark_search_page_screenshot(mock_concert):
    expected = b"png-bytes"
    with patch("app.services.crawler.async_playwright", return_value=_make_pw_mock(expected)):
        result = await crawl_interpark(mock_concert)
    assert result == expected


# goods/ 링크 발견 시 상세 페이지로 이동
@pytest.mark.asyncio
async def test_crawl_interpark_navigates_to_detail(mock_concert):
    expected = b"detail-png"
    pw_mock = _make_pw_mock(expected, link_href="/goods/12345678")
    with patch("app.services.crawler.async_playwright", return_value=pw_mock):
        result = await crawl_interpark(mock_concert)
    assert result == expected


# Playwright 예외 시 None 반환
@pytest.mark.asyncio
async def test_crawl_interpark_returns_none_on_error(mock_concert):
    mock_cm = AsyncMock()
    mock_cm.__aenter__ = AsyncMock(side_effect=Exception("timeout"))
    mock_cm.__aexit__ = AsyncMock(return_value=None)
    with patch("app.services.crawler.async_playwright", return_value=mock_cm):
        result = await crawl_interpark(mock_concert)
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


# crawl_and_save 테스트

# INTERPARK 크롤링 성공 시 Concert.crawl_screenshot_url 저장
@pytest.mark.asyncio
async def test_crawl_and_save_interpark_updates_concert():
    concert_id = uuid.uuid4()
    fake_url = "https://s3.example.com/crawls/screenshot.png"

    mock_concert = MagicMock()
    mock_concert.id = concert_id
    mock_concert.name = "공연명"

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
    mock_db.commit.assert_awaited_once()


# 미지원 사이트는 크롤링 없이 종료
@pytest.mark.asyncio
async def test_crawl_and_save_unsupported_site_skips():
    with patch("app.services.crawler.AsyncSessionLocal") as mock_session:
        await crawl_and_save(uuid.uuid4(), "MELON")
    mock_session.assert_not_called()


# ticketing_site=None이면 크롤링 없이 종료
@pytest.mark.asyncio
async def test_crawl_and_save_none_ticketing_site_skips():
    with patch("app.services.crawler.AsyncSessionLocal") as mock_session:
        await crawl_and_save(uuid.uuid4(), None)
    mock_session.assert_not_called()


# 크롤링 결과 None이면 S3 업로드 없이 종료
@pytest.mark.asyncio
async def test_crawl_and_save_crawler_returns_none_skips_upload():
    concert_id = uuid.uuid4()
    mock_concert = MagicMock()
    mock_concert.id = concert_id
    mock_concert.name = "공연명"

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
    mock_db.commit.assert_not_awaited()


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
