import uuid
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from httpx import AsyncClient, ASGITransport

from app.main import app
from app.services.diary import send_diary_requests_to_llm
from conftest import _get_token, kopis_mock

_LLM_API_KEY = "test-llm-key"


# 헬퍼

def _make_kopis_xml(kopis_id: str) -> bytes:
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f"<dbs><db>"
        f"<mt20id>{kopis_id}</mt20id>"
        f"<prfnm>{kopis_id} 공연</prfnm>"
        f"<prfpdfrom>2030.06.01</prfpdfrom>"
        f"<prfpdto>2030.06.01</prfpdto>"
        f"<fcltynm>테스트공연장</fcltynm>"
        f'<poster>https://example.com/poster.jpg</poster>'
        f"<genrenm>대중음악</genrenm>"
        f"<prfcast>테스트아티스트</prfcast>"
        f"<pcseguidance>R석 110,000원</pcseguidance>"
        f"<sty>공연 소개</sty>"
        f"</db></dbs>"
    ).encode("utf-8")


async def _create_concert(kopis_id: str, token: str) -> str:
    with kopis_mock(_make_kopis_xml(kopis_id)):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.get(
                f"/api/v1/concerts/{kopis_id}",
                headers={"Authorization": f"Bearer {token}"},
            )
    assert res.status_code == 200
    return res.json()["id"]


async def _create_ticket(concert_id: str, token: str, review: str | None = None) -> str:
    body = {"concert_id": concert_id}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.post(
            "/api/v1/tickets",
            json=body,
            headers={"Authorization": f"Bearer {token}"},
        )
    assert res.status_code == 201
    ticket_id = res.json()["id"]

    if review is not None:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.patch(
                f"/api/v1/tickets/{ticket_id}",
                json={"review": review},
                headers={"Authorization": f"Bearer {token}"},
            )
        assert res.status_code == 200
    return ticket_id


def _llm_headers():
    return {"Authorization": f"Bearer {_LLM_API_KEY}"}


def _mock_httpx_client(status_code: int = 200):
    mock_response = MagicMock()
    mock_response.status_code = status_code
    if status_code >= 400:
        mock_response.raise_for_status.side_effect = Exception(f"HTTP {status_code}")
    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.post = AsyncMock(return_value=mock_response)
    return mock_client


# 일기 생성 요청 (POST /tickets/{id}/diary) 테스트 - 자정 배치 전송 방식으로 바뀌어서
# 요청 시점엔 LLM팀을 직접 호출하지 않고 diary_requested_at만 찍음

@pytest.mark.asyncio
async def test_request_diary_sets_requested_at_only():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_DIARY_REQ_{uuid.uuid4().hex[:6]}", token)
    ticket_id = await _create_ticket(concert_id, token, review="정말 좋았던 공연")

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.post(
            f"/api/v1/tickets/{ticket_id}/diary",
            headers={"Authorization": f"Bearer {token}"},
        )

    # 요청 시점엔 LLM팀 호출 없이 diary_requested_at만 찍히고 diary는 계속 비어있음
    assert res.status_code == 202
    assert res.json()["diary"] is None
    assert res.json()["diary_requested_at"] is not None


# 유저당 시간당 요청 상한 초과 시 429 테스트 (LLM 호출 비용 남용 방지)
@pytest.mark.asyncio
async def test_generate_diary_rate_limited_after_10_calls_per_hour():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_DIARY_RATE_{uuid.uuid4().hex[:6]}", token)
    ticket_id = await _create_ticket(concert_id, token, review="정말 좋았던 공연")
    headers = {"Authorization": f"Bearer {token}"}

    statuses = []
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        for _ in range(11):
            res = await ac.post(f"/api/v1/tickets/{ticket_id}/diary", headers=headers)
            statuses.append(res.status_code)

    assert statuses[:10] == [202] * 10
    assert statuses[10] == 429


@pytest.mark.asyncio
async def test_generate_diary_requires_review_400():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_DIARY_NOREVIEW_{uuid.uuid4().hex[:6]}", token)
    ticket_id = await _create_ticket(concert_id, token)  # review 없음

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.post(
            f"/api/v1/tickets/{ticket_id}/diary",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert res.status_code == 400


@pytest.mark.asyncio
async def test_generate_diary_not_found_404():
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.post(
            f"/api/v1/tickets/{uuid.uuid4()}/diary",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert res.status_code == 404


@pytest.mark.asyncio
async def test_ticket_response_includes_diary_field_default_null():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_DIARY_DEFAULT_{uuid.uuid4().hex[:6]}", token)
    ticket_id = await _create_ticket(concert_id, token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get(
            f"/api/v1/tickets/{ticket_id}",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert res.status_code == 200
    assert res.json()["diary"] is None


# 자정 배치(send_diary_requests_to_llm) 테스트

# 요청된 건만 LLM팀에 전송되는지 확인 (diary_requested_at 없는 티켓은 제외)
@pytest.mark.asyncio
async def test_send_diary_requests_sends_pending_only():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_DIARY_BATCH_{uuid.uuid4().hex[:6]}", token)
    ticket_id = await _create_ticket(concert_id, token, review="정말 좋았던 공연")

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.post(f"/api/v1/tickets/{ticket_id}/diary", headers={"Authorization": f"Bearer {token}"})

    mock_client = _mock_httpx_client()
    with patch("app.services.diary.settings.LLM_DIARY_URL", "https://llm.example.com/diary"), \
         patch("app.services.diary.httpx.AsyncClient", return_value=mock_client):
        await send_diary_requests_to_llm()

    sent_payload = mock_client.post.call_args.kwargs["json"]
    sent_ticket_ids = {item["ticket_id"] for item in sent_payload}
    assert ticket_id in sent_ticket_ids
    matching = next(item for item in sent_payload if item["ticket_id"] == ticket_id)
    assert matching["review"] == "정말 좋았던 공연"
    assert matching["concert_name"]


# diary_requested_at이 없는 티켓(요청 안 한 티켓)은 전송 대상에서 제외
@pytest.mark.asyncio
async def test_send_diary_requests_excludes_not_requested():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_DIARY_SKIP_{uuid.uuid4().hex[:6]}", token)
    ticket_id = await _create_ticket(concert_id, token, review="아직 요청 안 함")

    mock_client = _mock_httpx_client()
    with patch("app.services.diary.settings.LLM_DIARY_URL", "https://llm.example.com/diary"), \
         patch("app.services.diary.httpx.AsyncClient", return_value=mock_client):
        await send_diary_requests_to_llm()

    if mock_client.post.called:
        sent_payload = mock_client.post.call_args.kwargs["json"]
        assert ticket_id not in {item["ticket_id"] for item in sent_payload}


# LLM_DIARY_URL 미설정 시 전송 자체를 건너뜀
@pytest.mark.asyncio
async def test_send_diary_requests_skips_when_url_not_configured():
    mock_client = _mock_httpx_client()
    with patch("app.services.diary.settings.LLM_DIARY_URL", ""), \
         patch("app.services.diary.httpx.AsyncClient", return_value=mock_client):
        await send_diary_requests_to_llm()

    assert not mock_client.post.called


# 전송 실패해도 예외가 밖으로 새지 않고 로그만 남김 (배치 스케줄러가 죽지 않아야 함)
@pytest.mark.asyncio
async def test_send_diary_requests_swallows_error_on_failure():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_DIARY_FAIL_{uuid.uuid4().hex[:6]}", token)
    ticket_id = await _create_ticket(concert_id, token, review="좋았다")

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.post(f"/api/v1/tickets/{ticket_id}/diary", headers={"Authorization": f"Bearer {token}"})

    mock_client = _mock_httpx_client(status_code=500)
    with patch("app.services.diary.settings.LLM_DIARY_URL", "https://llm.example.com/diary"), \
         patch("app.services.diary.httpx.AsyncClient", return_value=mock_client):
        await send_diary_requests_to_llm()  # 예외 없이 종료되면 성공


# POST /tickets/{id}/diary-result 웹훅 테스트

# 정상 수신 시 diary 저장
@pytest.mark.asyncio
async def test_diary_result_webhook_saves_diary():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_DIARY_RESULT_{uuid.uuid4().hex[:6]}", token)
    ticket_id = await _create_ticket(concert_id, token, review="좋았다")

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.post(f"/api/v1/tickets/{ticket_id}/diary", headers={"Authorization": f"Bearer {token}"})

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/tickets/{ticket_id}/diary-result",
                json={"diary": "잊지 못할 밤이었다..."},
                headers=_llm_headers(),
            )

    assert res.status_code == 200
    assert res.json()["diary"] == "잊지 못할 밤이었다..."

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        get_res = await ac.get(
            f"/api/v1/tickets/{ticket_id}",
            headers={"Authorization": f"Bearer {token}"},
        )
    assert get_res.json()["diary"] == "잊지 못할 밤이었다..."


# 잘못된 API 키 → 401
@pytest.mark.asyncio
async def test_diary_result_webhook_invalid_api_key_401():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_DIARY_AUTH_{uuid.uuid4().hex[:6]}", token)
    ticket_id = await _create_ticket(concert_id, token, review="좋았다")

    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/tickets/{ticket_id}/diary-result",
                json={"diary": "일기"},
                headers={"Authorization": "Bearer wrong-key"},
            )

    assert res.status_code == 401


# 존재하지 않는 티켓 → 404
@pytest.mark.asyncio
async def test_diary_result_webhook_ticket_not_found_404():
    with patch("app.core.deps.settings") as mock_settings:
        mock_settings.LLM_EXTRACT_API_KEY = _LLM_API_KEY
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/tickets/{uuid.uuid4()}/diary-result",
                json={"diary": "일기"},
                headers=_llm_headers(),
            )

    assert res.status_code == 404
