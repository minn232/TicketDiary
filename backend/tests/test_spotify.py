from unittest.mock import AsyncMock, MagicMock, patch

import httpx
import pytest

from app.services.spotify import fetch_oembed_thumbnail


def _oembed_resp(status_code: int, thumbnail_url: str | None = None) -> MagicMock:
    resp = MagicMock()
    resp.status_code = status_code
    resp.json.return_value = {"thumbnail_url": thumbnail_url} if thumbnail_url else {}
    return resp


@pytest.mark.asyncio
async def test_fetch_oembed_thumbnail_returns_thumbnail_url():
    client = MagicMock()
    client.get = AsyncMock(return_value=_oembed_resp(200, "https://image-cdn-fa.spotifycdn.com/image/abc"))

    with patch("app.services.spotify._MIN_REQUEST_INTERVAL", 0):
        url = await fetch_oembed_thumbnail("https://open.spotify.com/artist/xyz", client=client)

    assert url == "https://image-cdn-fa.spotifycdn.com/image/abc"


@pytest.mark.asyncio
async def test_fetch_oembed_thumbnail_none_on_http_error_status():
    client = MagicMock()
    client.get = AsyncMock(return_value=_oembed_resp(404))

    with patch("app.services.spotify._MIN_REQUEST_INTERVAL", 0):
        url = await fetch_oembed_thumbnail("https://open.spotify.com/artist/missing", client=client)

    assert url is None


@pytest.mark.asyncio
async def test_fetch_oembed_thumbnail_none_on_network_error():
    client = MagicMock()
    client.get = AsyncMock(side_effect=httpx.ConnectError("boom"))

    with patch("app.services.spotify._MIN_REQUEST_INTERVAL", 0):
        url = await fetch_oembed_thumbnail("https://open.spotify.com/artist/xyz", client=client)

    assert url is None
