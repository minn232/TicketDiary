from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from app.services.page_image import fetch_page_image, is_supported_page


# has_photo: 벅스 아티스트 페이지에서 실제 사진이 있을 때만 붙는 사진첩 링크
def _html_resp(og_image: str | None, status_code: int = 200, has_photo: bool = True) -> MagicMock:
    resp = MagicMock()
    resp.status_code = status_code
    meta = f'<meta property="og:image" content="{og_image}" />' if og_image else ""
    photos = '<a onclick="openPageLayer(20216907, 1, this);"></a>' if has_photo else ""
    resp.text = f"<html><head>{meta}</head><body>{photos}</body></html>"
    return resp


def test_is_supported_page():
    assert is_supported_page("https://music.bugs.co.kr/artist/20216907")
    assert is_supported_page("https://www.youtube.com/@bvlabel")
    assert is_supported_page("https://www.youtube.com/channel/UC6eb6z9")
    assert not is_supported_page("https://www.youtube.com/watch?v=abc")
    assert not is_supported_page("https://www.instagram.com/oysters.999/")


@pytest.mark.asyncio
async def test_fetch_page_image_returns_bugs_og_image():
    client = MagicMock()
    client.get = AsyncMock(return_value=_html_resp("https://image.bugsm.co.kr/artist/images/1200/202169/20216907.jpg"))

    with patch("app.services.page_image._MIN_REQUEST_INTERVAL", 0):
        url = await fetch_page_image("https://music.bugs.co.kr/artist/20216907", client=client)

    assert url == "https://image.bugsm.co.kr/artist/images/1200/202169/20216907.jpg"


@pytest.mark.asyncio
async def test_fetch_page_image_unescapes_youtube_og_image():
    client = MagicMock()
    client.get = AsyncMock(return_value=_html_resp("https://yt3.googleusercontent.com/abc=s900-c-k&amp;x=1"))

    with patch("app.services.page_image._MIN_REQUEST_INTERVAL", 0):
        url = await fetch_page_image("https://www.youtube.com/@bvlabel", client=client)

    assert url == "https://yt3.googleusercontent.com/abc=s900-c-k&x=1"


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "page,og_image,has_photo",
    [
        ("https://www.youtube.com/@x", "https://www.youtube.com/img/desktop/yt_1200.png", True),  # 사이트 로고
        # 사진 없는 아티스트 - 주소 형식은 실제 사진과 같은 이니셜 기본 이미지
        ("https://music.bugs.co.kr/artist/1", "https://image.bugsm.co.kr/artist/images/1200/144960/14496051.jpg", False),
        ("https://music.bugs.co.kr/artist/1", None, True),
    ],
)
async def test_fetch_page_image_rejects_logo_placeholder_or_missing(page, og_image, has_photo):
    client = MagicMock()
    client.get = AsyncMock(return_value=_html_resp(og_image, has_photo=has_photo))

    with patch("app.services.page_image._MIN_REQUEST_INTERVAL", 0):
        url = await fetch_page_image(page, client=client)

    assert url is None


@pytest.mark.asyncio
async def test_fetch_page_image_skips_unsupported_page_without_request():
    client = MagicMock()
    client.get = AsyncMock()

    url = await fetch_page_image("https://www.instagram.com/oysters.999/", client=client)

    assert url is None
    client.get.assert_not_awaited()
