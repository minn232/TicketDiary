import uuid
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from httpx import AsyncClient, ASGITransport

from app.main import app
from conftest import _get_token, kopis_mock


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


def _mock_diary_client(diary_text: str = "장문으로 가공된 일기", status_code: int = 200):
    mock_response = MagicMock()
    mock_response.status_code = status_code
    mock_response.json.return_value = {"diary": diary_text}
    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.post = AsyncMock(return_value=mock_response)
    return mock_client


@pytest.mark.asyncio
async def test_generate_diary_success():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_DIARY_OK_{uuid.uuid4().hex[:6]}", token)
    ticket_id = await _create_ticket(concert_id, token, review="정말 좋았던 공연")

    mock_client = _mock_diary_client("잊지 못할 밤이었다...")
    with patch("app.services.diary.settings.LLM_DIARY_URL", "https://llm.example.com/diary"), \
         patch("app.services.diary.httpx.AsyncClient", return_value=mock_client):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/tickets/{ticket_id}/diary",
                headers={"Authorization": f"Bearer {token}"},
            )

    # 백그라운드로 넘어가므로 응답 시점엔 아직 diary가 비어있고, 요청 시각만 찍힘
    assert res.status_code == 202
    assert res.json()["diary"] is None
    assert res.json()["diary_requested_at"] is not None

    # 전송된 payload에 한줄평과 공연 정보가 실렸는지 확인
    sent_payload = mock_client.post.call_args.kwargs["json"]
    assert sent_payload["review"] == "정말 좋았던 공연"
    assert sent_payload["concert_name"]

    # 백그라운드 태스크 완료 후(테스트 환경에선 응답 시점에 이미 실행됨) GET으로 재확인
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        get_res = await ac.get(
            f"/api/v1/tickets/{ticket_id}",
            headers={"Authorization": f"Bearer {token}"},
        )
    assert get_res.json()["diary"] == "잊지 못할 밤이었다..."


# 유저당 시간당 요청 상한 초과 시 429 테스트 (LLM 호출 비용 남용 방지)
@pytest.mark.asyncio
async def test_generate_diary_rate_limited_after_10_calls_per_hour():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_DIARY_RATE_{uuid.uuid4().hex[:6]}", token)
    ticket_id = await _create_ticket(concert_id, token, review="정말 좋았던 공연")
    headers = {"Authorization": f"Bearer {token}"}

    mock_client = _mock_diary_client("일기")
    statuses = []
    with patch("app.services.diary.settings.LLM_DIARY_URL", "https://llm.example.com/diary"), \
         patch("app.services.diary.httpx.AsyncClient", return_value=mock_client):
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


# LLM_DIARY_URL 미설정은 이제 백그라운드 태스크 내부에서만 실패하므로(request_ticket_diary
# 자체는 review 여부만 확인), 응답은 여전히 202이고 diary만 계속 비어있는지로 확인
@pytest.mark.asyncio
async def test_generate_diary_url_not_configured_stays_null():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_DIARY_NOURL_{uuid.uuid4().hex[:6]}", token)
    ticket_id = await _create_ticket(concert_id, token, review="좋았다")

    with patch("app.services.diary.settings.LLM_DIARY_URL", ""):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/tickets/{ticket_id}/diary",
                headers={"Authorization": f"Bearer {token}"},
            )

    assert res.status_code == 202

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        get_res = await ac.get(
            f"/api/v1/tickets/{ticket_id}",
            headers={"Authorization": f"Bearer {token}"},
        )
    assert get_res.json()["diary"] is None


# LLM팀 응답 오류도 백그라운드에서 로그만 남기고 삼켜지므로, diary가 null로 남는지로 확인
@pytest.mark.asyncio
async def test_generate_diary_llm_error_response_stays_null():
    token = await _get_token()
    concert_id = await _create_concert(f"PF_DIARY_ERR_{uuid.uuid4().hex[:6]}", token)
    ticket_id = await _create_ticket(concert_id, token, review="좋았다")

    mock_client = _mock_diary_client(status_code=500)
    with patch("app.services.diary.settings.LLM_DIARY_URL", "https://llm.example.com/diary"), \
         patch("app.services.diary.httpx.AsyncClient", return_value=mock_client):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/tickets/{ticket_id}/diary",
                headers={"Authorization": f"Bearer {token}"},
            )

    assert res.status_code == 202

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        get_res = await ac.get(
            f"/api/v1/tickets/{ticket_id}",
            headers={"Authorization": f"Bearer {token}"},
        )
    assert get_res.json()["diary"] is None


@pytest.mark.asyncio
async def test_generate_diary_not_found_404():
    token = await _get_token()

    with patch("app.services.diary.settings.LLM_DIARY_URL", "https://llm.example.com/diary"):
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
