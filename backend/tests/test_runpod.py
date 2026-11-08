from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from app.services.runpod import (
    _fetch_ssh_endpoint,
    _start_log_path,
    _wait_until_actually_stopped,
    candidate_pod_ids,
    start_pod,
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
# runtime이 없다는 이유로 RUNNING인 pod도 바로 "정지됨"으로 판정했음
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


def _patch_graphql(*results):
    return patch("app.services.runpod._graphql", AsyncMock(side_effect=list(results)))


# 꺼진 pod은 podResume(gpuCount 1)으로 켬 - REST /start는 남은 gpuCount 0을 그대로 써서 보조 pod이
# GPU 없이(메모리 488MB) 켜졌음(10/17)
@pytest.mark.asyncio
async def test_start_pod_resumes_with_gpu():
    graphql = AsyncMock(side_effect=[
        {"pod": {"desiredStatus": "EXITED", "gpuCount": 0}},
        {"podResume": {"id": "test-pod", "desiredStatus": "RUNNING", "gpuCount": 1}},
    ])
    with patch.multiple("app.services.runpod.settings", RUNPOD_API_KEY="test-key", RUNPOD_POD_ID="test-pod"), \
         patch("app.services.runpod._graphql", graphql):
        assert await start_pod() is True
    assert "gpuCount: 1" in graphql.call_args_list[1].args[0]


# GPU 부족 등으로 podResume이 errors를 주면 실패, 정지는 안 보냄(안 켜졌으므로)
@pytest.mark.asyncio
async def test_start_pod_false_when_resume_errors():
    stop = AsyncMock(return_value=True)
    with patch.multiple("app.services.runpod.settings", RUNPOD_API_KEY="test-key", RUNPOD_POD_ID="test-pod"), \
         _patch_graphql({"pod": {"desiredStatus": "EXITED", "gpuCount": 1}}, RuntimeError("not enough free GPUs")), \
         patch("app.services.runpod._stop_one_pod", stop):
        assert await start_pod() is False
    stop.assert_not_awaited()


# 그래도 GPU 0개로 켜졌으면(이미 떠 있던 경우 포함) 바로 정지하고 실패 - 설치 25분을 날리지 않게
@pytest.mark.asyncio
@pytest.mark.parametrize("results", [
    ({"pod": {"desiredStatus": "EXITED"}}, {"podResume": {"desiredStatus": "RUNNING", "gpuCount": 0}}),
    ({"pod": {"desiredStatus": "RUNNING", "gpuCount": 0}},),
])
async def test_start_pod_stops_when_no_gpu(results):
    stop = AsyncMock(return_value=True)
    with patch.multiple("app.services.runpod.settings", RUNPOD_API_KEY="test-key", RUNPOD_POD_ID="test-pod"), \
         _patch_graphql(*results), patch("app.services.runpod._stop_one_pod", stop):
        assert await start_pod() is False
    stop.assert_awaited_once_with("test-pod")


# 이미 GPU로 떠 있으면 다시 resume하지 않음
@pytest.mark.asyncio
async def test_start_pod_skips_resume_when_running_with_gpu():
    graphql = AsyncMock(return_value={"pod": {"desiredStatus": "RUNNING", "gpuCount": 1}})
    with patch.multiple("app.services.runpod.settings", RUNPOD_API_KEY="test-key", RUNPOD_POD_ID="test-pod"), \
         patch("app.services.runpod._graphql", graphql):
        assert await start_pod() is True
    assert graphql.await_count == 1


# ---- 매번 새 pod 생성·삭제 방식 ----
_NEW_MODE = {
    "RUNPOD_API_KEY": "test-key",
    "RUNPOD_TEMPLATE_ID": "tmpl",
    "RUNPOD_NETWORK_VOLUME_ID": "vol",
    "RUNPOD_GPU_TYPE_IDS": " A40, L4 ,A40",
    "RUNPOD_POD_NAME": "td-llm-batch",
    "RUNPOD_SSH_KEY_PATH": "/key",
}


def _new_mode():
    return patch.multiple("app.services.runpod.settings", **_NEW_MODE)


def test_new_pod_mode_requires_all_three_settings_and_dedupes_gpus():
    from app.services.runpod import gpu_type_ids, new_pod_mode

    with _new_mode():
        assert new_pod_mode() is True
        assert gpu_type_ids() == ["A40", "L4"]
    for missing in ("RUNPOD_TEMPLATE_ID", "RUNPOD_NETWORK_VOLUME_ID", "RUNPOD_GPU_TYPE_IDS"):
        with patch.multiple("app.services.runpod.settings", **{**_NEW_MODE, missing: ""}):
            assert new_pod_mode() is False


# 새 방식에서 stop_pod은 기존 후보 pod 정지 대신 이름으로 찾아 삭제함
@pytest.mark.asyncio
async def test_stop_pod_deletes_named_pods_in_new_mode():
    with _new_mode(), patch("app.services.runpod.delete_named_pods", AsyncMock(return_value=True)) as deleter:
        assert await stop_pod() is True
    deleter.assert_awaited_once()


@pytest.mark.asyncio
async def test_delete_named_pods_noop_when_none_exist():
    from app.services.runpod import delete_named_pods

    with _new_mode(), patch("app.services.runpod._list_named_pods", AsyncMock(return_value=[])), \
         patch("app.services.runpod._delete_pod", AsyncMock()) as deleter:
        assert await delete_named_pods() is True
    deleter.assert_not_awaited()


@pytest.mark.asyncio
async def test_delete_named_pods_true_only_when_gone_confirmed():
    from app.services.runpod import delete_named_pods

    for gone, expected in ((True, True), (False, False)):
        with _new_mode(), patch("app.services.runpod._list_named_pods", AsyncMock(return_value=[{"id": "p1"}])), \
             patch("app.services.runpod._delete_pod", AsyncMock(return_value=True)), \
             patch("app.services.runpod._wait_until_pods_gone", AsyncMock(return_value=gone)):
            assert await delete_named_pods() is expected


@pytest.mark.asyncio
async def test_delete_named_pods_false_when_delete_request_fails():
    from app.services.runpod import delete_named_pods

    with _new_mode(), patch("app.services.runpod._list_named_pods", AsyncMock(return_value=[{"id": "p1"}])), \
         patch("app.services.runpod._delete_pod", AsyncMock(return_value=False)), \
         patch("app.services.runpod._wait_until_pods_gone", AsyncMock()) as waiter:
        assert await delete_named_pods() is False
    waiter.assert_not_awaited()


@pytest.mark.asyncio
async def test_new_pod_launch_creates_when_none_exist():
    with _new_mode(), patch("app.services.runpod._list_named_pods", AsyncMock(return_value=[])), \
         patch("app.services.runpod._create_pod", AsyncMock(return_value="p1")) as creator, \
         patch("app.services.runpod._launch_services", AsyncMock(return_value=True)):
        assert await start_pod_and_launch_services() is True
    creator.assert_awaited_once()


# 같은 이름의 RUNNING pod이 있으면 새로 안 만들고 이어 씀
@pytest.mark.asyncio
async def test_new_pod_launch_reuses_running_pod():
    existing = [{"id": "p1", "status": "RUNNING"}]
    with _new_mode(), patch("app.services.runpod._list_named_pods", AsyncMock(return_value=existing)), \
         patch("app.services.runpod._create_pod", AsyncMock()) as creator, \
         patch("app.services.runpod._launch_services", AsyncMock(return_value=True)) as launcher:
        assert await start_pod_and_launch_services() is True
    creator.assert_not_awaited()
    launcher.assert_awaited_once_with("p1")


# RUNNING이 아닌 잔재는 지우고 새로 만듦
@pytest.mark.asyncio
async def test_new_pod_launch_deletes_stale_pod_first():
    existing = [{"id": "old", "status": "EXITED"}]
    with _new_mode(), patch("app.services.runpod._list_named_pods", AsyncMock(return_value=existing)), \
         patch("app.services.runpod._delete_pod", AsyncMock(return_value=True)) as deleter, \
         patch("app.services.runpod._wait_until_pods_gone", AsyncMock(return_value=True)), \
         patch("app.services.runpod._create_pod", AsyncMock(return_value="new")), \
         patch("app.services.runpod._launch_services", AsyncMock(return_value=True)):
        assert await start_pod_and_launch_services() is True
    deleter.assert_awaited_once_with("old")


# 기동 실패 → 삭제 후 새 pod으로 1회만 더, 둘 다 실패하면 pod이 안 남게 삭제하고 False
@pytest.mark.asyncio
async def test_new_pod_launch_retries_once_then_gives_up_and_deletes():
    with _new_mode(), patch("app.services.runpod._list_named_pods", AsyncMock(return_value=[])), \
         patch("app.services.runpod._create_pod", AsyncMock(side_effect=["p1", "p2"])) as creator, \
         patch("app.services.runpod._launch_services", AsyncMock(return_value=False)), \
         patch("app.services.runpod._delete_pod", AsyncMock(return_value=True)) as deleter, \
         patch("app.services.runpod._wait_until_pods_gone", AsyncMock(return_value=True)):
        assert await start_pod_and_launch_services() is False
    assert creator.await_count == 2
    assert [c.args[0] for c in deleter.await_args_list] == ["p1", "p2"]


@pytest.mark.asyncio
async def test_new_pod_launch_second_attempt_can_succeed():
    with _new_mode(), patch("app.services.runpod._list_named_pods", AsyncMock(return_value=[])), \
         patch("app.services.runpod._create_pod", AsyncMock(side_effect=["p1", "p2"])), \
         patch("app.services.runpod._launch_services", AsyncMock(side_effect=[False, True])), \
         patch("app.services.runpod._delete_pod", AsyncMock(return_value=True)) as deleter, \
         patch("app.services.runpod._wait_until_pods_gone", AsyncMock(return_value=True)):
        assert await start_pod_and_launch_services() is True
    deleter.assert_awaited_once_with("p1")


# 생성 자체가 실패(GPU 부족)하면 재시도 없이 False, 지울 pod도 없음
@pytest.mark.asyncio
async def test_new_pod_launch_false_when_create_fails():
    with _new_mode(), patch("app.services.runpod._list_named_pods", AsyncMock(return_value=[])), \
         patch("app.services.runpod._create_pod", AsyncMock(return_value=None)) as creator, \
         patch("app.services.runpod._delete_pod", AsyncMock()) as deleter:
        assert await start_pod_and_launch_services() is False
    creator.assert_awaited_once()
    deleter.assert_not_awaited()


# 새 설정이 비어 있으면 기존 후보 pod 방식 그대로 - 목록 조회·생성이 불리지 않아야 함
@pytest.mark.asyncio
async def test_legacy_mode_untouched_when_new_settings_empty():
    with patch.multiple("app.services.runpod.settings", RUNPOD_API_KEY="test-key", RUNPOD_POD_ID="test-pod",
                        RUNPOD_TEMPLATE_ID="", RUNPOD_NETWORK_VOLUME_ID="", RUNPOD_GPU_TYPE_IDS=""), \
         patch("app.services.runpod._create_pod", AsyncMock()) as creator, \
         patch("app.services.runpod._start_and_launch_one", AsyncMock(return_value=True)) as legacy:
        assert await start_pod_and_launch_services() is True
    creator.assert_not_awaited()
    legacy.assert_awaited_once_with("test-pod")


# v2 생성: GPU 후보를 순서대로 시도, 400(재고 없음)이면 다음 GPU, 첫 성공에서 멈춤
@pytest.mark.asyncio
async def test_create_pod_tries_next_gpu_on_400_and_stops_on_success():
    from app.services.runpod import _create_pod

    attempts = AsyncMock(side_effect=[(400, "no capacity", None), (201, "{}", "pod-x")])
    with _new_mode(), patch("app.services.runpod._try_create_with_gpu", attempts):
        assert await _create_pod() == "pod-x"
    assert [c.args[0] for c in attempts.await_args_list] == ["A40", "L4"]


# 인증·잔액·본문 오류는 다른 GPU로 해도 같아서 첫 시도에서 중단
@pytest.mark.asyncio
@pytest.mark.parametrize("status", [401, 402, 422, 429])
async def test_create_pod_aborts_on_config_errors(status):
    from app.services.runpod import _create_pod

    attempts = AsyncMock(return_value=(status, "bad", None))
    with _new_mode(), patch("app.services.runpod._try_create_with_gpu", attempts):
        assert await _create_pod() is None
    assert attempts.await_count == 1


@pytest.mark.asyncio
async def test_create_pod_none_when_all_gpus_fail():
    from app.services.runpod import _create_pod

    attempts = AsyncMock(return_value=(400, "no capacity", None))
    with _new_mode(), patch("app.services.runpod._try_create_with_gpu", attempts):
        assert await _create_pod() is None
    assert attempts.await_count == 2


# 요청 본문: GPU 1종, Global 볼륨을 /workspace에 마운트
@pytest.mark.asyncio
async def test_try_create_with_gpu_sends_v2_body():
    from app.services.runpod import _try_create_with_gpu

    response = MagicMock(status_code=201, text="{}")
    response.json.return_value = {"id": "pod-1"}
    client = _mock_post_client()
    client.post = AsyncMock(return_value=response)
    with _new_mode(), patch("app.services.runpod.httpx.AsyncClient", return_value=client):
        assert await _try_create_with_gpu("A40", "n", "tmpl", "vol") == (201, "{}", "pod-1")
    url = client.post.await_args.args[0]
    body = client.post.await_args.kwargs["json"]
    assert url == "https://api.runpod.io/v2/pods"
    assert body["gpu"] == {"id": "A40", "count": 1}
    assert body["mounts"] == {"global": [{"volumeId": "vol", "path": "/workspace"}]}
    assert body["templateId"] == "tmpl"


# 목록은 이름이 같고 TERMINATED가 아닌 것만, 페이지를 넘겨가며 모음
@pytest.mark.asyncio
async def test_list_named_pods_filters_by_name_and_status_across_pages():
    from app.services.runpod import _list_named_pods

    pages = [
        {"pods": [{"id": "a", "name": "td-llm-batch", "status": "RUNNING"}, {"id": "b", "name": "other", "status": "RUNNING"}],
         "pagination": {"nextCursor": "c1", "hasNextPage": True}},
        {"pods": [{"id": "c", "name": "td-llm-batch", "status": "TERMINATED"}, {"id": "d", "name": "td-llm-batch", "status": "EXITED"}],
         "pagination": {"nextCursor": None, "hasNextPage": False}},
    ]
    responses = []
    for page in pages:
        r = MagicMock()
        r.json.return_value = page
        r.raise_for_status = MagicMock()
        responses.append(r)
    client = _mock_post_client()
    client.get = AsyncMock(side_effect=responses)
    with _new_mode(), patch("app.services.runpod.httpx.AsyncClient", return_value=client):
        result = await _list_named_pods()
    assert [p["id"] for p in result] == ["a", "d"]


# 서버 개인키에서 공개키를 뽑고 추가 키를 줄바꿈으로 이어 붙임(템플릿 PUBLIC_KEY는 줄바꿈이 빠져 두 키가 붙었었음)
def test_authorized_public_keys_joins_server_and_extra_keys_by_newline(tmp_path):
    import asyncssh

    from app.services.runpod import _authorized_public_keys

    key = asyncssh.generate_private_key("ssh-ed25519")
    key_path = tmp_path / "id"
    key_path.write_bytes(key.export_private_key())
    server_pub = key.export_public_key().decode().strip()
    with patch.multiple("app.services.runpod.settings", RUNPOD_SSH_KEY_PATH=str(key_path),
                        RUNPOD_EXTRA_PUBLIC_KEYS="ssh-ed25519 AAA llm-team; ssh-ed25519 BBB other"):
        assert _authorized_public_keys() == f"{server_pub}\nssh-ed25519 AAA llm-team\nssh-ed25519 BBB other"


def test_authorized_public_keys_none_when_key_unreadable():
    from app.services.runpod import _authorized_public_keys

    with patch.multiple("app.services.runpod.settings", RUNPOD_SSH_KEY_PATH="/no/such/key", RUNPOD_EXTRA_PUBLIC_KEYS=""):
        assert _authorized_public_keys() is None
