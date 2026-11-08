import asyncio
import logging
from datetime import datetime, timezone

import asyncssh
import httpx

from app.core.config import settings
from app.core.http_errors import describe_http_error

logger = logging.getLogger(__name__)

_RUNPOD_PODS_URL = "https://rest.runpod.io/v1/pods"
_STOPPED_STATUSES = {"EXITED", "TERMINATED"}


# 시도 순서대로의 후보 pod ID 목록 - 기본 pod(RUNPOD_POD_ID) 먼저, 그다음 보조 pod들. 한 pod이
# 묶인 호스트의 GPU가 차면 그 pod은 계속 못 뜨므로 다른 호스트의 pod으로 넘어가기 위함
def candidate_pod_ids() -> list[str]:
    ids = [settings.RUNPOD_POD_ID, *settings.RUNPOD_FALLBACK_POD_IDS.split(",")]
    return list(dict.fromkeys(i.strip() for i in ids if i.strip()))


# ---- 매번 새 pod 생성·삭제 방식 ----
# 템플릿·볼륨·GPU 후보가 모두 설정돼 있을 때만 켜짐(config.py). 꺼져 있으면 위 후보 pod stop/resume 방식 그대로.
# pod은 id를 저장하지 않고 고정 이름(RUNPOD_POD_NAME)으로 찾아 씀 - 서버 재시작·생성 응답 유실로 id를
# 잃어도 남은 pod을 찾아 지울 수 있고, 이름이 다른 LLM팀 수동 pod은 건드리지 않음
def new_pod_mode() -> bool:
    return bool(
        settings.RUNPOD_API_KEY
        and settings.RUNPOD_TEMPLATE_ID
        and settings.RUNPOD_NETWORK_VOLUME_ID
        and gpu_type_ids()
    )


def gpu_type_ids() -> list[str]:
    return list(dict.fromkeys(g.strip() for g in settings.RUNPOD_GPU_TYPE_IDS.split(",") if g.strip()))


# Global 볼륨은 v1 REST(networkVolumeId)가 못 붙여서("network volume not found", 11/9 실측) v2 API를 씀.
# v2 차이: 목록에 name 필터가 없어 클라이언트에서 거름, 상태 필드가 desiredStatus가 아니라 status
# (PROVISIONING/STARTING/RUNNING/EXITED/ERROR/TERMINATED), GPU 종류는 요청당 1개(여러 개를 한 번에 못 줌)
_RUNPOD_V2_PODS_URL = "https://api.runpod.io/v2/pods"
_VOLUME_MOUNT_PATH = "/workspace"


def _auth_headers() -> dict:
    return {"Authorization": f"Bearer {settings.RUNPOD_API_KEY}"}


async def _list_named_pods(name: str | None = None) -> list[dict]:
    name = name or settings.RUNPOD_POD_NAME
    pods: list[dict] = []
    cursor = None
    async with httpx.AsyncClient(timeout=30.0) as client:
        for _ in range(10):
            response = await client.get(
                _RUNPOD_V2_PODS_URL, params={"cursor": cursor} if cursor else None, headers=_auth_headers()
            )
            response.raise_for_status()
            data = response.json()
            pods.extend(data.get("pods", []))
            pagination = data.get("pagination") or {}
            cursor = pagination.get("nextCursor")
            if not pagination.get("hasNextPage") or not cursor:
                break
    return [p for p in pods if p.get("name") == name and p.get("status") != "TERMINATED"]


# pod의 authorized_keys용 PUBLIC_KEY 값(줄바꿈 구분) - 서버 개인키에서 공개키를 뽑고 추가 키를 이어 붙임.
# 서버 키를 못 뽑으면 None으로 템플릿 값을 그대로 씀(SSH가 안 되면 기동 단계에서 실패로 잡힘)
def _authorized_public_keys() -> str | None:
    keys: list[str] = []
    if settings.RUNPOD_SSH_KEY_PATH:
        try:
            keys.append(asyncssh.read_private_key(settings.RUNPOD_SSH_KEY_PATH).export_public_key().decode().strip())
        except Exception as e:
            logger.warning(f"[LLM] 서버 SSH 공개키를 만들지 못함 - 템플릿 PUBLIC_KEY 그대로 사용: {describe_http_error(e)}")
            return None
    keys += [k.strip() for k in settings.RUNPOD_EXTRA_PUBLIC_KEYS.split(";") if k.strip()]
    return "\n".join(keys) or None


# GPU 종류 하나로 생성 요청 1회. (HTTP 상태, 본문 일부, pod id)를 돌려줌 - 전송 오류면 상태 None.
# 재고 없음은 400(detail 문장뿐, 코드 없음)이라 호출부가 다음 GPU로 넘어감
async def _try_create_with_gpu(gpu_id: str, name: str, template_id: str, volume_id: str) -> tuple[int | None, str, str | None]:
    body = {
        "name": name,
        "templateId": template_id,
        "cloud": "SECURE",
        "gpu": {"id": gpu_id, "count": 1},
        "mounts": {"global": [{"volumeId": volume_id, "path": _VOLUME_MOUNT_PATH}]},
    }
    public_keys = _authorized_public_keys()
    if public_keys:
        # 템플릿 env와 키별로 합쳐지고 요청 값이 이김
        body["env"] = {"PUBLIC_KEY": public_keys}
    try:
        async with httpx.AsyncClient(timeout=60.0) as client:
            response = await client.post(_RUNPOD_V2_PODS_URL, headers=_auth_headers(), json=body)
    except Exception as e:
        return None, describe_http_error(e), None
    text = " ".join(response.text.split())[:400]
    pod_id = response.json().get("id") if response.status_code in (200, 201) else None
    return response.status_code, text, pod_id


# 설정 문제(인증·잔액·본문 오류·429)는 다른 GPU로 해도 같으니 바로 중단, 400(재고 없음 포함)·5xx·전송 오류는 다음 GPU로.
# 전부 실패하면 None - 호출부는 다음 스케줄 시도에 맡김(생성 실패는 과금 없음)
_ABORT_STATUSES = {401, 402, 403, 404, 422, 429}


async def _create_pod() -> str | None:
    for gpu_id in gpu_type_ids():
        status, text, pod_id = await _try_create_with_gpu(
            gpu_id, settings.RUNPOD_POD_NAME, settings.RUNPOD_TEMPLATE_ID, settings.RUNPOD_NETWORK_VOLUME_ID
        )
        if pod_id:
            logger.info(f"[LLM] RunPod pod 생성됨 (pod={pod_id}, gpu={gpu_id}, name={settings.RUNPOD_POD_NAME})")
            return pod_id
        logger.warning(f"[LLM] RunPod pod 생성 실패 (gpu={gpu_id}): HTTP {status} {text}")
        if status in _ABORT_STATUSES:
            break
    logger.error("[LLM] RunPod pod 생성 실패 - 후보 GPU에서 pod을 못 잡음")
    return None


async def _delete_pod(pod_id: str) -> bool:
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.delete(f"{_RUNPOD_V2_PODS_URL}/{pod_id}", headers=_auth_headers())
            # 성공은 204. 이미 지워진 pod은 404일 것으로 보이나 문서엔 없어 실측 필요 - 목표(없음)는 달성이라 성공 취급
            if response.status_code != 404:
                response.raise_for_status()
        return True
    except Exception as e:
        logger.error(f"[LLM] RunPod pod 삭제 요청 실패 (pod={pod_id}): {describe_http_error(e)}")
        return False


# 삭제 뒤 단건 조회가 어떻게 오는지 확실치 않아 id 조회 대신 이름 목록에서 사라졌는지로 판정함.
# 조회 오류는 재시도로 넘김(일시 오류로 "남아 있다"고 오판해도 다음 정지 시도가 멱등으로 다시 지움)
async def _wait_until_pods_gone(pod_ids: set[str], timeout_seconds: float = 120.0, interval_seconds: float = 5.0) -> bool:
    elapsed = 0.0
    while elapsed < timeout_seconds:
        try:
            remaining = {p.get("id") for p in await _list_named_pods()}
            if not (remaining & pod_ids):
                return True
        except Exception as e:
            logger.warning(f"pod 삭제 확인 중 조회 오류(재시도함): {e}")
        await asyncio.sleep(interval_seconds)
        elapsed += interval_seconds
    return False


# 정지 대신 삭제 - 밤배치 조기완료·시각 정지·유휴 안전망 등 여러 경로에서 불려 멱등이어야 함(없으면 True).
# 반환값은 "요청 성공"이 아니라 "이름 조회에서 실제로 사라짐"
async def delete_named_pods() -> bool:
    try:
        pods = await _list_named_pods()
    except Exception as e:
        logger.error(f"[LLM] RunPod pod 목록 조회 실패 - 삭제 못 함: {describe_http_error(e)}")
        return False
    if not pods:
        return True
    ids = {p["id"] for p in pods if p.get("id")}
    results = [await _delete_pod(pod_id) for pod_id in ids]
    if not all(results):
        return False
    if await _wait_until_pods_gone(ids):
        logger.info(f"[LLM] RunPod pod 삭제 확인됨 (pod={sorted(ids)})")
        return True
    logger.error(f"[LLM] RunPod pod 삭제 요청은 성공했지만 사라진 것을 확인하지 못함 - 남아 있을 수 있음 (pod={sorted(ids)})")
    return False


async def _llm_server_healthy() -> bool:
    if not settings.LLM_CRAWL_URL:
        return False
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            return (await client.get(settings.LLM_CRAWL_URL.rsplit("/", 1)[0] + "/health")).status_code == 200
    except Exception:
        return False


# run_start_script_via_ssh가 만드는 tmux 세션(llm_start)이 아직 살아 있으면 기동 스크립트가 도는 중.
# SSH가 안 되면 판단 못 하므로 False(호출부가 새로 기동해 안전한 쪽으로)
async def _start_script_running(pod_id: str) -> bool:
    try:
        async with await _ssh_connect(pod_id, connect_timeout=10) as conn:
            result = await conn.run(f"tmux has-session -t {_TMUX_SESSION}", check=False)
        return result.exit_status == 0
    except Exception:
        return False


# 새 pod 방식의 기동. 같은 이름의 RUNNING pod이 이미 있으면(03시 시도가 도는 중 등) 새로 만들지 않고 그걸 이어 씀
# - 기존 방식도 이미 RUNNING이면 resume 없이 SSH·스크립트만 다시 하던 것과 같음. RUNNING이 아닌 잔재는 지우고 새로 만듦.
# 기동에 실패하면 pod을 지우고 새 pod으로 1회만 더 시도(호스트가 문제인 경우를 피하려고). 그래도 실패하면 pod이 안 남게
# 지운 뒤 False(다음 스케줄 시도에 맡김)
async def _create_and_launch_new_pod() -> bool:
    try:
        existing = await _list_named_pods()
    except Exception as e:
        logger.error(f"[LLM] RunPod pod 목록 조회 실패 - 기동 중단: {describe_http_error(e)}")
        return False
    pod_id = next((p["id"] for p in existing if p.get("status") == "RUNNING" and p.get("id")), None)
    stale = {p["id"] for p in existing if p.get("id") and p["id"] != pod_id}
    if stale:
        logger.warning(f"[LLM] 이름이 같은 RUNNING 아닌 잔재 pod 삭제 후 진행 (pod={sorted(stale)})")
        for stale_id in stale:
            await _delete_pod(stale_id)
        if not await _wait_until_pods_gone(stale):
            logger.error("[LLM] 잔재 pod 삭제를 확인하지 못해 기동 중단")
            return False

    # 이미 RUNNING인 pod을 이어 쓰는 경우 start_vllm.sh를 무조건 다시 돌리면 떠 있던 vLLM·터널이 끊김(11/9 03시 정기
    # 배치가 수동 테스트 pod에 끼어들어 health가 530으로 떨어짐) - 살아 있으면 그대로 쓰고, 기동 스크립트가
    # 아직 도는 중이면 재실행 없이 준비만 기다림. 둘 다 아닐 때만 아래에서 다시 기동
    if pod_id is not None and settings.RUNPOD_SSH_KEY_PATH:
        if await _llm_server_healthy():
            logger.info(f"[LLM] 이미 켜진 pod의 llm_server가 살아 있어 그대로 사용 (pod={pod_id})")
            return True
        if await _start_script_running(pod_id):
            logger.info(f"[LLM] 기동 스크립트가 진행 중이라 재실행 없이 준비 대기 (pod={pod_id})")
            if await wait_until_llm_server_ready():
                return True
            logger.error(f"[LLM] 진행 중이던 기동이 끝내 준비되지 않음 - 삭제 후 새 pod으로 (pod={pod_id})")
            await _delete_pod(pod_id)
            await _wait_until_pods_gone({pod_id})
            pod_id = None

    for attempt in (1, 2):
        if pod_id is None:
            pod_id = await _create_pod()
        if pod_id is None:
            # 생성 자체 실패(GPU 부족 등)는 재시도해도 같은 결과일 가능성이 커서 바로 포기
            return False
        if not settings.RUNPOD_SSH_KEY_PATH:
            return True
        if await _launch_services(pod_id):
            return True
        logger.error(f"[LLM] 새 pod 기동 실패 - 삭제 (시도 {attempt}/2, pod={pod_id})")
        await _delete_pod(pod_id)
        await _wait_until_pods_gone({pod_id})
        pod_id = None
    return False


_RUNPOD_GRAPHQL_URL = "https://api.runpod.io/graphql"
_POD_GPU_QUERY = "query($id: String!) { pod(input: {podId: $id}) { desiredStatus gpuCount } }"
_POD_RESUME_MUTATION = (
    "mutation($id: String!) { podResume(input: {podId: $id, gpuCount: 1}) { id desiredStatus gpuCount } }"
)


# GraphQL 요청. 오류도 HTTP 200에 errors로 오므로(존재하지 않는 pod 등) errors가 있으면 예외로 바꿈
async def _graphql(query: str, variables: dict) -> dict:
    async with httpx.AsyncClient(timeout=30.0) as client:
        response = await client.post(
            _RUNPOD_GRAPHQL_URL,
            headers={"Authorization": f"Bearer {settings.RUNPOD_API_KEY}"},
            json={"query": query, "variables": variables},
        )
        response.raise_for_status()
        data = response.json()
    if data.get("errors"):
        raise RuntimeError("; ".join(str(err.get("message")) for err in data["errors"]))
    return data.get("data") or {}


# RunPod pod 재개 - GPU 비용 절감으로 KST 00시 전후에만 띄우는 정책이라 배치 전송 전에 깨움. REST /start는 GPU
# 개수를 못 받아 GPU 0개로 켜져 vllm 설치가 OOM으로 죽었음 → GraphQL podResume에 gpuCount 1 지정 후 GPU 개수
# 재확인. 이미 떠 있으면 GPU 개수만 확인, pod_id 없으면 기본 pod(수동 스크립트용)
async def start_pod(pod_id: str | None = None) -> bool:
    pod_id = pod_id or settings.RUNPOD_POD_ID
    if not settings.RUNPOD_API_KEY or not pod_id:
        logger.info("RUNPOD_API_KEY/RUNPOD_POD_ID 미설정, pod 시작 건너뜀")
        return False
    try:
        pod = (await _graphql(_POD_GPU_QUERY, {"id": pod_id})).get("pod") or {}
        if pod.get("desiredStatus") != "RUNNING":
            pod = (await _graphql(_POD_RESUME_MUTATION, {"id": pod_id})).get("podResume") or {}
    except Exception as e:
        logger.error(f"[LLM] RunPod pod 시작 요청 실패 (pod={pod_id}): {describe_http_error(e)}")
        return False
    if (pod.get("gpuCount") or 0) < 1:
        logger.error(f"[LLM] RunPod pod이 GPU 없이 켜짐 - 바로 정지 (pod={pod_id}, gpuCount={pod.get('gpuCount')})")
        await _stop_one_pod(pod_id)
        return False
    logger.info(f"[LLM] RunPod pod 시작 요청 성공 (pod={pod_id}, gpuCount={pod.get('gpuCount')})")
    return True


# pod 상태 조회(REST v1). 응답에 "runtime" 필드가 아예 없어서(10/16 실제 응답 확인) 상태는
# desiredStatus(RUNNING/EXITED/TERMINATED)로만 알 수 있음 - 과금도 이 값 기준
async def _fetch_pod_status(pod_id: str) -> dict:
    async with httpx.AsyncClient(timeout=15.0) as client:
        response = await client.get(
            f"{_RUNPOD_PODS_URL}/{pod_id}",
            headers={"Authorization": f"Bearer {settings.RUNPOD_API_KEY}"},
        )
        response.raise_for_status()
        return response.json()


# stop 요청 뒤 실제로 꺼졌는지 확인. RunPod API가 stop 요청에 200을 줘도 실제 종료는 비동기라
# 시간이 걸릴 수 있고, API 레벨 성공이 실제 종료를 보장하지 않으므로 GET으로 재확인한다
async def _wait_until_actually_stopped(
    pod_id: str, timeout_seconds: float = 120.0, interval_seconds: float = 10.0
) -> bool:
    elapsed = 0.0
    while elapsed < timeout_seconds:
        try:
            data = await _fetch_pod_status(pod_id)
            # 예전엔 runtime 유무로 봤는데 v1 응답엔 그 필드가 없어 항상 바로 "정지됨"이 됐음.
            # 필드가 빠지거나 값이 낯설면 꺼진 걸로 치지 않음(켜진 채 과금되는 쪽이 더 나쁨)
            if data.get("desiredStatus") in _STOPPED_STATUSES:
                return True
        except Exception as e:
            logger.warning(f"pod 상태 확인 중 오류(재시도함): {e}")
        await asyncio.sleep(interval_seconds)
        elapsed += interval_seconds
    return False


# pod 정지 - 밤배치 조기완료 시 즉시 + 자정 배치 종료 후 안전망 + 1시간 뒤 백업까지 여러
# 경로에서 호출됨(멱등이라 중복 호출 무해, 누락이 훨씬 나쁨). 어느 후보가 떠 있는지 기억하지 않고
# 후보 전부에 정지를 보냄. 반환값은 "요청 성공"이 아니라 "전부 실제로 꺼짐"
async def stop_pod() -> bool:
    if new_pod_mode():
        return await delete_named_pods()
    pod_ids = candidate_pod_ids()
    if not settings.RUNPOD_API_KEY or not pod_ids:
        logger.info("RUNPOD_API_KEY/RUNPOD_POD_ID 미설정, pod 정지 건너뜀")
        return False
    results = [await _stop_one_pod(pod_id) for pod_id in pod_ids]
    return all(results)


async def _stop_one_pod(pod_id: str) -> bool:
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(
                f"{_RUNPOD_PODS_URL}/{pod_id}/stop",
                headers={"Authorization": f"Bearer {settings.RUNPOD_API_KEY}"},
            )
            response.raise_for_status()
        logger.info(f"[LLM] RunPod pod 정지 요청 성공, 실제 정지 확인 중... (pod={pod_id})")
    except Exception as e:
        logger.error(f"[LLM] RunPod pod 정지 요청 실패 (pod={pod_id}): {describe_http_error(e)}")
        return False

    if await _wait_until_actually_stopped(pod_id):
        logger.info(f"[LLM] RunPod pod 실제 정지 확인됨 (pod={pod_id})")
        return True
    logger.error(f"[LLM] RunPod pod 정지 요청은 성공했지만 실제 정지를 확인하지 못함 - 계속 켜져있을 수 있음 (pod={pod_id})")
    return False


# pod을 깨운 직후 llm_server 헬스체크(base+"/health")가 응답할 때까지 폴링, 안 되면 False(다음날 재시도).
# 기본 1500초 = 매 기동 vLLM 재설치(컨테이너 디스크가 stop마다 초기화, 5~10분) + vLLM 준비 최대 10분
# abort_check: 기동 스크립트가 이미 실패했는지 보는 함수(실패 사유 문자열 또는 None) - 스크립트가
# 설치 단계에서 죽어도 health는 530만 내서 1500초를 다 기다린 뒤에야 다음 후보로 넘어갔음(10/16)
async def wait_until_llm_server_ready(
    timeout_seconds: float = 1500.0,
    interval_seconds: float = 10.0,
    abort_check=None,
    abort_check_every: int = 3,
) -> bool:
    if not settings.LLM_CRAWL_URL:
        return False

    health_url = settings.LLM_CRAWL_URL.rsplit("/", 1)[0] + "/health"
    elapsed = 0.0
    polls = 0
    last_status = "응답 없음"
    async with httpx.AsyncClient(timeout=10.0) as client:
        while elapsed < timeout_seconds:
            try:
                response = await client.get(health_url)
                if response.status_code == 200:
                    logger.info(f"[LLM] llm_server 준비 확인됨 (약 {elapsed:.0f}초 소요)")
                    return True
                last_status = f"HTTP {response.status_code}"
            except Exception as e:
                last_status = describe_http_error(e)
            polls += 1
            if abort_check and polls % abort_check_every == 0:
                reason = await abort_check()
                if reason:
                    logger.error(f"[LLM] 기동 스크립트 실패로 준비 대기 중단 (약 {elapsed:.0f}초 시점): {reason}")
                    return False
            await asyncio.sleep(interval_seconds)
            elapsed += interval_seconds

    # 530=cloudflared 터널 없음, 502=터널은 떴는데 llm_server 미기동 등 원인이 달라 마지막 상태를 남김
    logger.error(f"[LLM] llm_server가 {timeout_seconds:.0f}초 안에 준비되지 않음 (마지막 상태: {last_status})")
    return False


# RunPod SSH 외부 매핑 포트는 pod을 stop/start할 때마다 바뀌어(.env 고정값 불가) 접속 직전에 API로 조회함(캐싱
# 안 함, pod 시작 때만 불려 비용 무시). REST v1 portMappings는 {"22": 포트} 한 칸에 tcp/udp 중 아무거나(주로 udp)
# 들어와 Connection refused가 났음 - GraphQL은 포트별 type을 줘서 tcp 22만 고름
_SSH_PORTS_QUERY = (
    "query($id: String!) { pod(input: {podId: $id}) "
    "{ runtime { ports { ip isIpPublic privatePort publicPort type } } } }"
)


async def _fetch_ssh_endpoint(pod_id: str) -> tuple[str, int]:
    async with httpx.AsyncClient(timeout=15.0) as client:
        response = await client.post(
            _RUNPOD_GRAPHQL_URL,
            headers={"Authorization": f"Bearer {settings.RUNPOD_API_KEY}"},
            json={"query": _SSH_PORTS_QUERY, "variables": {"id": pod_id}},
        )
        response.raise_for_status()
        data = response.json()
    pod = (data.get("data") or {}).get("pod") or {}
    ports = (pod.get("runtime") or {}).get("ports") or []
    for port in ports:
        if port.get("privatePort") == 22 and port.get("type") == "tcp" and port.get("isIpPublic"):
            return port["ip"], int(port["publicPort"])
    # pod이 막 시작된 직후엔 runtime/포트가 아직 안 잡혀있을 수 있음 - 호출부
    # (_wait_for_ssh_ready)가 이미 재시도 루프라 예외만 던지면 다음 폴링에서 다시 조회됨
    raise RuntimeError("pod의 SSH 접속 정보(공인 IP의 22/tcp)가 아직 준비되지 않음")


# Container Start Command 자동화가 리스크로 무산돼(pod 편집이 리셋 유발) SSH 원격 실행으로
# 대체함. known_hosts=None으로 호스트키 검증 생략 - 우리가 통제하는 전용 pod 하나뿐이라
# 안 바뀔 걸로 보이지만 100% 확신은 못 해서, 바뀌어도 자동화가 안 끊기게 일부러 뺌
async def _ssh_connect(pod_id: str, **overrides):
    host, port = await _fetch_ssh_endpoint(pod_id)
    return await asyncssh.connect(
        host,
        port=port,
        username=settings.RUNPOD_SSH_USER,
        client_keys=[settings.RUNPOD_SSH_KEY_PATH],
        known_hosts=None,
        **overrides,
    )


# pod은 켜졌어도 OS/SSH 데몬이 뜨는 데 시간이 걸릴 수 있어 SSH 접속 자체가 될 때까지 폴링
async def _wait_for_ssh_ready(
    pod_id: str | None = None, timeout_seconds: float = 180.0, interval_seconds: float = 10.0
) -> bool:
    pod_id = pod_id or settings.RUNPOD_POD_ID
    if not settings.RUNPOD_API_KEY or not pod_id or not settings.RUNPOD_SSH_KEY_PATH:
        return False

    elapsed = 0.0
    last_error = "시도 없음"
    while elapsed < timeout_seconds:
        try:
            async with await _ssh_connect(pod_id, connect_timeout=10):
                logger.info(f"[LLM] SSH 접속 준비 확인됨 (pod={pod_id}, 약 {elapsed:.0f}초 소요)")
                return True
        except Exception as e:
            last_error = describe_http_error(e)
        await asyncio.sleep(interval_seconds)
        elapsed += interval_seconds

    # Permission denied(키 불일치)와 연결 거부/포트 미할당(아직 부팅 중)은 대응이 달라 마지막 예외를 남김
    logger.error(f"[LLM] SSH가 {timeout_seconds:.0f}초 안에 준비되지 않음 (pod={pod_id}, 마지막 오류: {last_error})")
    return False


# pod에 SSH로 접속해 /workspace/start_vllm.sh(vLLM+llm_server+cloudflared 기동)를 tmux
# 세션으로 원격 실행 - nohup은 세션이 사라져 실행 중 개입할 방법이 없어서, tmux면 나중에
# `tmux attach -t llm_start`로 들어와 같은 화면을 보고 타이핑도 할 수 있음. 재실행 시 이전
# 세션과 충돌 방지로 먼저 kill-session 정리, 실제 준비 확인은 wait_until_llm_server_ready()가 함
_TMUX_SESSION = "llm_start"
# start_vllm.sh는 vLLM을 `> vllm.log 2>&1 &`로 떼어놔서 llm_start 세션에 붙어도 래퍼 스크립트
# 안내문만 보이고 vLLM 실시간 로그는 안 보임 - 로그를 따라가는 tmux 세션을 하나 더 둠.
# `tail -F`(--retry 포함)라 vllm.log가 아직 없어도 생기는 대로 알아서 따라붙음
_TMUX_LOG_SESSION = "vllm_log"
_VLLM_LOG_PATH = "/workspace/server/vllm.log"


# 스크립트 출력 로그를 pod·실행 시각별로 분리 - 주/보조 pod, 03시/07시 실행이 한 파일을 덮어써서
# 남은 로그가 어느 실행 것인지 알 수 없었음(10/16 LLM팀 지적)
def _start_log_path(pod_id: str) -> str:
    return f"/workspace/start_vllm_remote_{pod_id}_{datetime.now(timezone.utc):%m%d_%H%M}.log"


# 스크립트가 실패하면 "ERROR: ..." 줄을 남김(setup_local.sh 실패, GPU 없음 등) - 그 줄이 보이면
# 더 기다려도 안 뜨므로 바로 포기. SSH 자체가 안 되면 판단 보류(None)하고 health 대기를 이어감
async def _start_script_failure(pod_id: str, log_path: str) -> str | None:
    try:
        async with await _ssh_connect(pod_id, connect_timeout=10) as conn:
            result = await conn.run(f"grep -m1 '^ERROR' {log_path}", check=False)
    except Exception:
        return None
    line = str(result.stdout or "").strip()
    return line[:300] or None


async def run_start_script_via_ssh(pod_id: str | None = None, log_path: str | None = None) -> bool:
    pod_id = pod_id or settings.RUNPOD_POD_ID
    if not settings.RUNPOD_API_KEY or not pod_id or not settings.RUNPOD_SSH_KEY_PATH:
        logger.info("RUNPOD_API_KEY/POD_ID/SSH_KEY_PATH 미설정, 원격 실행 건너뜀")
        return False
    log_path = log_path or _start_log_path(pod_id)
    try:
        async with await _ssh_connect(pod_id, connect_timeout=15) as conn:
            # tmux는 /workspace 밖에 설치돼서 pod을 stop/start하면 사라짐 - 없으면 아래 new-session이
            # 조용히 실패해(check=False) start_vllm.sh가 아예 안 돌므로 매번 먼저 확인해 설치
            await _run_remote(
                conn,
                "tmux 설치 확인",
                "command -v tmux >/dev/null || (apt-get update -qq && apt-get install -y -qq tmux)",
            )
            await conn.run(f"tmux kill-session -t {_TMUX_SESSION} 2>/dev/null; true", check=False)
            # 끝에 sleep infinity - 스크립트가 끝나 세션이 닫히면 nohup/disown 없이 `&`로 띄운 vLLM이 같이 죽음.
            # 11/9 새 pod 시험에서 start_vllm.sh는 "vLLM OK"까지 찍고 끝났는데 직후 vLLM 프로세스만 사라져
            # llm_server가 APIConnectionError로 전부 실패, 콜백 0건(uvicorn·cloudflared는 nohup이라 살아남음).
            # 세션을 계속 열어두면 막힘 - pod은 배치 뒤 삭제되니 남겨도 무해
            # asyncssh conn.run은 비대화형 셸이라 .bashrc가 앞에서 return해 RunPod pod 환경변수
            # (/etc/rp_environment, .bashrc 끝에서 source됨)가 안 실림 - 직접 로그인 실행과 환경을 맞춤
            await _run_remote(
                conn,
                "start_vllm.sh 세션 생성",
                f"tmux new-session -d -s {_TMUX_SESSION} -c /workspace "
                f"'. /etc/rp_environment 2>/dev/null; bash -l start_vllm.sh 2>&1 | tee {log_path}; sleep infinity'",
            )
            await conn.run(f"tmux kill-session -t {_TMUX_LOG_SESSION} 2>/dev/null; true", check=False)
            await _run_remote(
                conn,
                "vLLM 로그 세션 생성",
                f"tmux new-session -d -s {_TMUX_LOG_SESSION} "
                f"'tail -n 50 -F {_VLLM_LOG_PATH}'",
            )
        logger.info(
            f"[LLM] start_vllm.sh 원격 실행 요청 완료 (pod={pod_id}, tmux 세션 '{_TMUX_SESSION}'=스크립트 진행상황, "
            f"'{_TMUX_LOG_SESSION}'=vLLM 실시간 로그, 둘 다 SSH로 attach 가능, 스크립트 로그={log_path})"
        )
        return True
    except Exception as e:
        logger.error(f"[LLM] start_vllm.sh 원격 실행 실패 (pod={pod_id}): {describe_http_error(e)}")
        return False


# check=False라 실패해도 예외가 안 나서(tmux 미설치로 세션이 안 만들어져 start_vllm.sh가 조용히
# 안 도는 경우 등) 종료 코드와 stderr를 남겨 원인이 보이게 함
async def _run_remote(conn, label: str, command: str) -> None:
    result = await conn.run(command, check=False)
    if result.exit_status != 0:
        logger.error(f"[LLM] 원격 명령 실패 ({label}): exit={result.exit_status} stderr={str(result.stderr).strip()[:300]}")


# 후보 pod을 순서대로 시작 → SSH 준비 → start_vllm.sh 원격 실행 → llm_server 준비까지 시도해
# 처음 성공한 하나를 씀. 스케줄러의 llm_attempt job이 start_pod() 대신 이 함수를 호출한다
async def start_pod_and_launch_services() -> bool:
    if new_pod_mode():
        return await _create_and_launch_new_pod()
    pod_ids = candidate_pod_ids()
    if not settings.RUNPOD_API_KEY or not pod_ids:
        logger.info("RUNPOD_API_KEY/RUNPOD_POD_ID 미설정, pod 시작 건너뜀")
        return False
    for index, pod_id in enumerate(pod_ids, start=1):
        if index > 1:
            logger.warning(f"[LLM] 보조 pod으로 재시도 ({index}/{len(pod_ids)}, pod={pod_id})")
        if await _start_and_launch_one(pod_id):
            return True
    logger.error(f"[LLM] 후보 pod {len(pod_ids)}개 모두 기동 실패")
    return False


async def _start_and_launch_one(pod_id: str) -> bool:
    if not await start_pod(pod_id):
        # start 자체가 실패하면(GPU 부족 등) 안 켜진 상태라 정지할 필요 없음
        return False
    if not settings.RUNPOD_SSH_KEY_PATH:
        # SSH 설정이 아직 없으면(과도기) pod만 켜고 끝 - LLM팀이 수동으로 start_vllm.sh를
        # 돌려야 하는 예전 방식 그대로 유지되는 것뿐이라 안전하게 건너뜀
        return True
    if await _launch_services(pod_id):
        return True
    # 켜졌는데 못 쓰는 pod은 과금되지 않게 바로 정지하고 다음 후보로 넘어감
    await _stop_one_pod(pod_id)
    return False


async def _launch_services(pod_id: str) -> bool:
    if not await _wait_for_ssh_ready(pod_id):
        logger.error(f"[LLM] pod은 켜졌지만 SSH 접속이 준비되지 않아 원격 실행을 포기함 (pod={pod_id})")
        return False
    log_path = _start_log_path(pod_id)
    if not await run_start_script_via_ssh(pod_id, log_path):
        return False
    # 후보 모두 같은 cloudflared 터널이라 health URL은 같음. 여기서 확인해야 vLLM이 안 뜬 pod을
    # 버리고 다음 후보로 넘어갈 수 있음(호출부의 준비 대기는 이미 떠 있어 바로 통과)
    if settings.LLM_CRAWL_URL and not await wait_until_llm_server_ready(
        abort_check=lambda: _start_script_failure(pod_id, log_path)
    ):
        return False
    return True
