from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from app.services.runpod import (
    _fetch_ssh_endpoint,
    _start_log_path,
    _wait_until_actually_stopped,
    candidate_pod_ids,
    start_pod_and_launch_services,
    stop_pod,
    wait_until_llm_server_ready,
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


# desiredStatus가 EXITED면(=꺼짐) 첫 조회에서 바로 True
@pytest.mark.asyncio
async def test_wait_until_actually_stopped_true_immediately():
    mock_client = _mock_get_client([{"desiredStatus": "EXITED"}])
    with patch("app.services.runpod.settings.RUNPOD_API_KEY", "test-key"), \
         patch("app.services.runpod.settings.RUNPOD_POD_ID", "test-pod"), \
         patch("app.services.runpod.httpx.AsyncClient", return_value=mock_client):
        result = await _wait_until_actually_stopped("test-pod", timeout_seconds=1.0, interval_seconds=0.01)
    assert result is True


# 처음엔 RUNNING이다가(아직 안 꺼짐) 다음 폴링에서 EXITED면 - 재시도 루프가 실제로 동작하는지 확인
@pytest.mark.asyncio
async def test_wait_until_actually_stopped_true_after_polling():
    mock_client = _mock_get_client([{"desiredStatus": "RUNNING"}, {"desiredStatus": "EXITED"}])
    with patch("app.services.runpod.settings.RUNPOD_API_KEY", "test-key"), \
         patch("app.services.runpod.settings.RUNPOD_POD_ID", "test-pod"), \
         patch("app.services.runpod.httpx.AsyncClient", return_value=mock_client):
        result = await _wait_until_actually_stopped("test-pod", timeout_seconds=1.0, interval_seconds=0.01)
    assert result is True
    assert mock_client.get.call_count == 2


# 타임아웃 안에 계속 RUNNING이면(실제로 안 꺼짐) False
@pytest.mark.asyncio
async def test_wait_until_actually_stopped_false_on_timeout():
    mock_client = _mock_get_client([{"desiredStatus": "RUNNING"}] * 10)
    with patch("app.services.runpod.settings.RUNPOD_API_KEY", "test-key"), \
         patch("app.services.runpod.settings.RUNPOD_POD_ID", "test-pod"), \
         patch("app.services.runpod.httpx.AsyncClient", return_value=mock_client):
        result = await _wait_until_actually_stopped("test-pod", timeout_seconds=0.05, interval_seconds=0.01)
    assert result is False


# 실제 v1 응답처럼 runtime 필드도 desiredStatus도 없으면 꺼진 걸로 치지 않음 - 예전 코드는
# runtime이 없다는 이유로 RUNNING인 pod도 바로 "정지됨"으로 판정했음(10/16 발견)
@pytest.mark.asyncio
async def test_wait_until_actually_stopped_not_fooled_by_missing_fields():
    mock_client = _mock_get_client([{"id": "test-pod", "desiredStatus": "RUNNING"}, {"id": "test-pod"}] * 5)
    with patch("app.services.runpod.settings.RUNPOD_API_KEY", "test-key"),          patch("app.services.runpod.settings.RUNPOD_POD_ID", "test-pod"),          patch("app.services.runpod.httpx.AsyncClient", return_value=mock_client):
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


def _mock_health_client(status_code: int):
    response = MagicMock(status_code=status_code)
    client = MagicMock()
    client.__aenter__ = AsyncMock(return_value=client)
    client.__aexit__ = AsyncMock(return_value=None)
    client.get = AsyncMock(return_value=response)
    return client


# 기동 스크립트가 ERROR를 남기면 health 대기 시간을 다 채우지 않고 바로 포기
@pytest.mark.asyncio
async def test_wait_ready_aborts_when_start_script_failed():
    abort_check = AsyncMock(side_effect=[None, "ERROR: setup_local.sh 실패"])
    with patch("app.services.runpod.settings.LLM_CRAWL_URL", "https://llm.example.com/crawl"), \
         patch("app.services.runpod.httpx.AsyncClient", return_value=_mock_health_client(530)), \
         patch("app.services.runpod.asyncio.sleep", AsyncMock()):
        result = await wait_until_llm_server_ready(
            timeout_seconds=1500.0, abort_check=abort_check, abort_check_every=1
        )
    assert result is False
    assert abort_check.await_count == 2


# 실패 확인이 판단 보류(None)만 내면 기존처럼 timeout까지 기다림
@pytest.mark.asyncio
async def test_wait_ready_keeps_waiting_when_no_failure_seen():
    abort_check = AsyncMock(return_value=None)
    client = _mock_health_client(530)
    with patch("app.services.runpod.settings.LLM_CRAWL_URL", "https://llm.example.com/crawl"), \
         patch("app.services.runpod.httpx.AsyncClient", return_value=client), \
         patch("app.services.runpod.asyncio.sleep", AsyncMock()):
        result = await wait_until_llm_server_ready(
            timeout_seconds=60.0, interval_seconds=10.0, abort_check=abort_check, abort_check_every=3
        )
    assert result is False
    assert client.get.await_count == 6
    assert abort_check.await_count == 2


# 로그 파일 이름에 pod ID가 들어가 주/보조 pod 로그가 섞이지 않음
def test_start_log_path_is_per_pod():
    a, b = _start_log_path("pod-a"), _start_log_path("pod-b")
    assert a.startswith("/workspace/start_vllm_remote_pod-a_") and a.endswith(".log")
    assert a != b


def _mock_graphql_client(ports):
    response = MagicMock()
    response.raise_for_status = MagicMock()
    response.json.return_value = {"data": {"pod": {"runtime": {"ports": ports} if ports is not None else None}}}
    client = MagicMock()
    client.__aenter__ = AsyncMock(return_value=client)
    client.__aexit__ = AsyncMock(return_value=None)
    client.post = AsyncMock(return_value=response)
    return client


# 22/udp가 먼저 와도 22/tcp 공인 포트를 고름 - REST portMappings가 udp 포트를 줘서 SSH가
# Connection refused로 실패하던 문제(10/16 실제 응답 순서 그대로)
@pytest.mark.asyncio
async def test_fetch_ssh_endpoint_picks_public_tcp_22():
    ports = [
        {"ip": "213.192.2.86", "isIpPublic": True, "privatePort": 22, "publicPort": 40163, "type": "udp"},
        {"ip": "100.65.11.5", "isIpPublic": False, "privatePort": 8000, "publicPort": 60834, "type": "http"},
        {"ip": "213.192.2.86", "isIpPublic": True, "privatePort": 22, "publicPort": 40162, "type": "tcp"},
    ]
    with patch("app.services.runpod.settings.RUNPOD_API_KEY", "test-key"),          patch("app.services.runpod.httpx.AsyncClient", return_value=_mock_graphql_client(ports)):
        assert await _fetch_ssh_endpoint("pod-a") == ("213.192.2.86", 40162)


# 막 켜져서 runtime이 없거나 tcp 22가 아직 없으면 예외 - 재시도 루프가 다음 폴링에서 다시 조회
@pytest.mark.asyncio
@pytest.mark.parametrize("ports", [None, [{"ip": "1.2.3.4", "isIpPublic": True, "privatePort": 22, "publicPort": 1, "type": "udp"}]])
async def test_fetch_ssh_endpoint_raises_until_tcp_ready(ports):
    with patch("app.services.runpod.settings.RUNPOD_API_KEY", "test-key"),          patch("app.services.runpod.httpx.AsyncClient", return_value=_mock_graphql_client(ports)):
        with pytest.raises(RuntimeError):
            await _fetch_ssh_endpoint("pod-a")
