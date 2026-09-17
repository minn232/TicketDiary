from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from app.services.runpod import _wait_until_actually_stopped, stop_pod

_SETTINGS_PATCH = {
    "app.services.runpod.settings.RUNPOD_API_KEY": "test-key",
    "app.services.runpod.settings.RUNPOD_POD_ID": "test-pod",
}


def _mock_post_client(status_code: int = 200):
    mock_response = MagicMock()
    mock_response.status_code = status_code
    if status_code >= 400:
        mock_response.raise_for_status.side_effect = Exception(f"HTTP {status_code}")
    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.post = AsyncMock(return_value=mock_response)
    return mock_client


# stop 요청(POST) 자체가 실패하면 실제 정지 확인 단계로 넘어가지도 않고 바로 False
@pytest.mark.asyncio
async def test_stop_pod_returns_false_when_post_fails():
    mock_client = _mock_post_client(status_code=500)
    with patch("app.services.runpod.settings.RUNPOD_API_KEY", "test-key"), \
         patch("app.services.runpod.settings.RUNPOD_POD_ID", "test-pod"), \
         patch("app.services.runpod.httpx.AsyncClient", return_value=mock_client):
        result = await stop_pod()
    assert result is False


# POST는 성공했지만 실제 정지 확인(_wait_until_actually_stopped)이 안 되면 - "요청 성공"과
# "실제 정지"를 구분하는 이 기능의 핵심 케이스 - False를 반환해야 함
@pytest.mark.asyncio
async def test_stop_pod_returns_false_when_actual_stop_not_confirmed():
    mock_client = _mock_post_client(status_code=200)
    with patch("app.services.runpod.settings.RUNPOD_API_KEY", "test-key"), \
         patch("app.services.runpod.settings.RUNPOD_POD_ID", "test-pod"), \
         patch("app.services.runpod.httpx.AsyncClient", return_value=mock_client), \
         patch("app.services.runpod._wait_until_actually_stopped", AsyncMock(return_value=False)):
        result = await stop_pod()
    assert result is False


# POST 성공 + 실제 정지 확인까지 되면 True
@pytest.mark.asyncio
async def test_stop_pod_returns_true_when_actually_stopped():
    mock_client = _mock_post_client(status_code=200)
    with patch("app.services.runpod.settings.RUNPOD_API_KEY", "test-key"), \
         patch("app.services.runpod.settings.RUNPOD_POD_ID", "test-pod"), \
         patch("app.services.runpod.httpx.AsyncClient", return_value=mock_client), \
         patch("app.services.runpod._wait_until_actually_stopped", AsyncMock(return_value=True)):
        result = await stop_pod()
    assert result is True


# RUNPOD_API_KEY/POD_ID 미설정이면 아무 호출도 없이 바로 False (건너뛰기)
@pytest.mark.asyncio
async def test_stop_pod_skips_when_not_configured():
    mock_client = _mock_post_client(status_code=200)
    with patch("app.services.runpod.settings.RUNPOD_API_KEY", ""), \
         patch("app.services.runpod.settings.RUNPOD_POD_ID", ""), \
         patch("app.services.runpod.httpx.AsyncClient", return_value=mock_client):
        result = await stop_pod()
    assert result is False
    assert not mock_client.post.called


def _mock_get_client(json_side_effect):
    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)

    responses = []
    for data in json_side_effect:
        mock_response = MagicMock()
        mock_response.json.return_value = data
        mock_response.raise_for_status = MagicMock()
        responses.append(mock_response)
    mock_client.get = AsyncMock(side_effect=responses)
    return mock_client


# runtime이 없어지면(=실제로 꺼짐) 첫 조회에서 바로 True
@pytest.mark.asyncio
async def test_wait_until_actually_stopped_true_immediately():
    mock_client = _mock_get_client([{"runtime": None}])
    with patch("app.services.runpod.settings.RUNPOD_API_KEY", "test-key"), \
         patch("app.services.runpod.settings.RUNPOD_POD_ID", "test-pod"), \
         patch("app.services.runpod.httpx.AsyncClient", return_value=mock_client):
        result = await _wait_until_actually_stopped(timeout_seconds=1.0, interval_seconds=0.01)
    assert result is True


# 처음엔 runtime이 남아있다가(아직 안 꺼짐) 다음 폴링에서 사라지면 - 재시도 루프가 실제로 동작하는지 확인
@pytest.mark.asyncio
async def test_wait_until_actually_stopped_true_after_polling():
    mock_client = _mock_get_client([{"runtime": {"uptimeInSeconds": 10}}, {"runtime": None}])
    with patch("app.services.runpod.settings.RUNPOD_API_KEY", "test-key"), \
         patch("app.services.runpod.settings.RUNPOD_POD_ID", "test-pod"), \
         patch("app.services.runpod.httpx.AsyncClient", return_value=mock_client):
        result = await _wait_until_actually_stopped(timeout_seconds=1.0, interval_seconds=0.01)
    assert result is True
    assert mock_client.get.call_count == 2


# 타임아웃 안에 계속 runtime이 남아있으면(실제로 안 꺼짐) False
@pytest.mark.asyncio
async def test_wait_until_actually_stopped_false_on_timeout():
    mock_client = _mock_get_client([{"runtime": {"uptimeInSeconds": 10}}] * 10)
    with patch("app.services.runpod.settings.RUNPOD_API_KEY", "test-key"), \
         patch("app.services.runpod.settings.RUNPOD_POD_ID", "test-pod"), \
         patch("app.services.runpod.httpx.AsyncClient", return_value=mock_client):
        result = await _wait_until_actually_stopped(timeout_seconds=0.05, interval_seconds=0.01)
    assert result is False
