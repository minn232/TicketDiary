from unittest.mock import AsyncMock, MagicMock, patch

import httpx
import pytest

from app.services.wikidata import fetch_korean_label


def _entity_resp(qid: str, labels: dict) -> MagicMock:
    resp = MagicMock()
    resp.status_code = 200
    resp.json.return_value = {"entities": {qid: {"labels": labels}}}
    return resp


@pytest.mark.asyncio
async def test_fetch_korean_label_returns_ko_value():
    client = MagicMock()
    client.get = AsyncMock(
        return_value=_entity_resp("Q863748", {"ko": {"value": "스즈키 코노미"}, "en": {"value": "Konomi Suzuki"}})
    )

    with patch("app.services.wikidata._MIN_REQUEST_INTERVAL", 0):
        label = await fetch_korean_label("Q863748", client=client)

    assert label == "스즈키 코노미"


@pytest.mark.asyncio
async def test_fetch_korean_label_none_when_no_ko_label():
    client = MagicMock()
    client.get = AsyncMock(return_value=_entity_resp("Q1", {"en": {"value": "No Korean Wiki"}}))

    with patch("app.services.wikidata._MIN_REQUEST_INTERVAL", 0):
        label = await fetch_korean_label("Q1", client=client)

    assert label is None


@pytest.mark.asyncio
async def test_fetch_korean_label_gives_up_after_retries():
    client = MagicMock()
    client.get = AsyncMock(side_effect=httpx.ConnectError("boom"))

    with patch("app.services.wikidata._MIN_REQUEST_INTERVAL", 0), patch(
        "app.services.wikidata._RETRY_BACKOFF_SECONDS", 0
    ):
        label = await fetch_korean_label("Q1", client=client)

    assert label is None
    assert client.get.await_count == 3  # 초기 1회 + 재시도 2회
