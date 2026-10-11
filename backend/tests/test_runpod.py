from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from app.services.runpod import (
    _wait_until_actually_stopped,
    candidate_pod_ids,
    start_pod_and_launch_services,
    stop_pod,
)

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
        result = await _wait_until_actually_stopped("test-pod", timeout_seconds=1.0, interval_seconds=0.01)
    assert result is True


# 처음엔 runtime이 남아있다가(아직 안 꺼짐) 다음 폴링에서 사라지면 - 재시도 루프가 실제로 동작하는지 확인
@pytest.mark.asyncio
async def test_wait_until_actually_stopped_true_after_polling():
    mock_client = _mock_get_client([{"runtime": {"uptimeInSeconds": 10}}, {"runtime": None}])
    with patch("app.services.runpod.settings.RUNPOD_API_KEY", "test-key"), \
         patch("app.services.runpod.settings.RUNPOD_POD_ID", "test-pod"), \
         patch("app.services.runpod.httpx.AsyncClient", return_value=mock_client):
        result = await _wait_until_actually_stopped("test-pod", timeout_seconds=1.0, interval_seconds=0.01)
    assert result is True
    assert mock_client.get.call_count == 2


# 타임아웃 안에 계속 runtime이 남아있으면(실제로 안 꺼짐) False
@pytest.mark.asyncio
async def test_wait_until_actually_stopped_false_on_timeout():
    mock_client = _mock_get_client([{"runtime": {"uptimeInSeconds": 10}}] * 10)
    with patch("app.services.runpod.settings.RUNPOD_API_KEY", "test-key"), \
         patch("app.services.runpod.settings.RUNPOD_POD_ID", "test-pod"), \
         patch("app.services.runpod.httpx.AsyncClient", return_value=mock_client):
        result = await _wait_until_actually_stopped("test-pod", timeout_seconds=0.05, interval_seconds=0.01)
    assert result is False


# 기본 pod 먼저, 보조 pod은 쉼표 순서대로 - 공백/빈 값/중복은 걸러냄
def test_candidate_pod_ids_order_and_dedupe():
    with patch("app.services.runpod.settings.RUNPOD_POD_ID", "pod-a"), \
         patch("app.services.runpod.settings.RUNPOD_FALLBACK_POD_IDS", " pod-b, ,pod-a,pod-c "):
        assert candidate_pod_ids() == ["pod-a", "pod-b", "pod-c"]


# 정지는 어느 후보가 떠 있는지 모르므로 후보 전부에 보내고, 하나라도 확인 실패면 False
@pytest.mark.asyncio
async def test_stop_pod_stops_every_candidate():
    stop_one = AsyncMock(side_effect=[True, False])
    with patch("app.services.runpod.settings.RUNPOD_API_KEY", "test-key"), \
         patch("app.services.runpod.settings.RUNPOD_POD_ID", "pod-a"), \
         patch("app.services.runpod.settings.RUNPOD_FALLBACK_POD_IDS", "pod-b"), \
         patch("app.services.runpod._stop_one_pod", stop_one):
        result = await stop_pod()
    assert result is False
    assert [c.args[0] for c in stop_one.call_args_list] == ["pod-a", "pod-b"]


def _launch_patches(start_results, launch_results):
    return (
        patch("app.services.runpod.settings.RUNPOD_API_KEY", "test-key"),
        patch("app.services.runpod.settings.RUNPOD_POD_ID", "pod-a"),
        patch("app.services.runpod.settings.RUNPOD_FALLBACK_POD_IDS", "pod-b"),
        patch("app.services.runpod.settings.RUNPOD_SSH_KEY_PATH", "/key"),
        patch("app.services.runpod.start_pod", AsyncMock(side_effect=start_results)),
        patch("app.services.runpod._launch_services", AsyncMock(side_effect=launch_results)),
        patch("app.services.runpod._stop_one_pod", AsyncMock(return_value=True)),
    )


# 기본 pod start가 실패(GPU 부족)하면 정지 없이 보조 pod으로 넘어가 성공
@pytest.mark.asyncio
async def test_start_falls_back_when_primary_start_fails():
    p = _launch_patches([False, True], [True])
    with p[0], p[1], p[2], p[3], p[4] as start, p[5] as launch, p[6] as stop_one:
        result = await start_pod_and_launch_services()
    assert result is True
    assert [c.args[0] for c in start.call_args_list] == ["pod-a", "pod-b"]
    assert [c.args[0] for c in launch.call_args_list] == ["pod-b"]
    assert not stop_one.called


# 기본 pod은 켜졌지만 SSH/서버 기동에 실패하면 그 pod을 정지하고 보조 pod으로 넘어감
@pytest.mark.asyncio
async def test_start_stops_primary_and_falls_back_when_launch_fails():
    p = _launch_patches([True, True], [False, True])
    with p[0], p[1], p[2], p[3], p[4], p[5], p[6] as stop_one:
        result = await start_pod_and_launch_services()
    assert result is True
    assert [c.args[0] for c in stop_one.call_args_list] == ["pod-a"]


# 후보 전부 실패하면 False (켜졌다 실패한 pod은 각각 정지됨)
@pytest.mark.asyncio
async def test_start_returns_false_when_all_candidates_fail():
    p = _launch_patches([True, False], [False])
    with p[0], p[1], p[2], p[3], p[4], p[5], p[6] as stop_one:
        result = await start_pod_and_launch_services()
    assert result is False
    assert [c.args[0] for c in stop_one.call_args_list] == ["pod-a"]
