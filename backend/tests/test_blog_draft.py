import uuid
from datetime import date
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from app.core.database import AsyncSessionLocal
from app.main import app
from app.models.blog_draft import BlogDraft
from app.models.concert import Concert, EventType
from app.models.setlist import PreSetlist, RealSetlist
from app.services.blog_draft import send_blog_drafts_to_llm
from test_diary import _create_concert, _create_ticket
from conftest import _get_token

_BLOG_URL = "http://llm.test/blog-draft"


# 헬퍼

async def _post_draft(ticket_id: str, token: str, emotion: str = "음향이 좋았다. 다들 신나게 춤췄다."):
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        return await ac.post(
            f"/api/v1/tickets/{ticket_id}/blog-draft",
            json={"emotion": emotion},
            headers={"Authorization": f"Bearer {token}"},
        )


async def _get_draft(ticket_id: str, token: str):
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        return await ac.get(f"/api/v1/tickets/{ticket_id}/blog-draft", headers={"Authorization": f"Bearer {token}"})


async def _ticket(prefix: str) -> tuple[str, str, str]:
    token = await _get_token()
    concert_id = await _create_concert(f"{prefix}_{uuid.uuid4().hex[:6]}", token)
    ticket_id = await _create_ticket(concert_id, token)
    return token, concert_id, ticket_id


# LLM 서버 응답 흉내 - 요청 바디를 기록하고, 감상 글 그대로 제목/본문을 돌려줌(fail이면 502)
def _llm_client(calls: list[dict], fail: bool = False):
    async def _post(url, json=None, headers=None):
        calls.append(json)
        response = MagicMock()
        if fail:
            response.raise_for_status.side_effect = Exception("HTTP 502")
        response.json.return_value = {"title": json["concert_name"], "body": json["emotion"], "text": "무시됨"}
        return response

    client = MagicMock()
    client.__aenter__ = AsyncMock(return_value=client)
    client.__aexit__ = AsyncMock(return_value=None)
    client.post = AsyncMock(side_effect=_post)
    return patch("app.services.blog_draft.httpx.AsyncClient", return_value=client)


def _blog_url():
    return patch("app.services.blog_draft.settings.LLM_BLOG_URL", _BLOG_URL)


# 요청/조회

@pytest.mark.asyncio
async def test_draft_status_none_then_pending_after_request():
    token, _, ticket_id = await _ticket("PF_BLOG_REQ")

    assert (await _get_draft(ticket_id, token)).json()["status"] == "none"

    res = await _post_draft(ticket_id, token, emotion="  좋았다.  ")
    assert res.status_code == 202
    assert res.json()["status"] == "pending"
    assert res.json()["emotion"] == "좋았다."
    assert res.json()["text"] is None
    assert (await _get_draft(ticket_id, token)).json()["status"] == "pending"


@pytest.mark.asyncio
async def test_draft_rejects_empty_or_too_long_emotion():
    token, _, ticket_id = await _ticket("PF_BLOG_LEN")

    assert (await _post_draft(ticket_id, token, emotion="")).status_code == 422
    assert (await _post_draft(ticket_id, token, emotion="가" * 2001)).status_code == 422


@pytest.mark.asyncio
async def test_draft_rejects_festival():
    token, concert_id, ticket_id = await _ticket("PF_BLOG_FEST")
    async with AsyncSessionLocal() as db:
        concert = await db.get(Concert, uuid.UUID(concert_id))
        concert.event_type = EventType.FESTIVAL.value
        await db.commit()

    assert (await _post_draft(ticket_id, token)).status_code == 400


@pytest.mark.asyncio
async def test_draft_of_other_users_ticket_is_404():
    _, _, ticket_id = await _ticket("PF_BLOG_OWNER")
    other_token = await _get_token()

    assert (await _post_draft(ticket_id, other_token)).status_code == 404
    assert (await _get_draft(ticket_id, other_token)).status_code == 404


# 밤 배치 생성

@pytest.mark.asyncio
async def test_send_generates_draft_with_real_setlist_only():
    token, concert_id, ticket_id = await _ticket("PF_BLOG_SEND")
    async with AsyncSessionLocal() as db:
        db.add(RealSetlist(concert_id=uuid.UUID(concert_id), performance_date=date(2030, 6, 1),
                           songs=[{"name": "실제곡1"}, {"name": "실제곡2"}]))
        db.add(PreSetlist(concert_id=uuid.UUID(concert_id), songs=[{"name": "예상곡"}]))
        await db.commit()
    await _post_draft(ticket_id, token, emotion="음향이 좋았다.")

    calls: list[dict] = []
    with _blog_url(), _llm_client(calls):
        await send_blog_drafts_to_llm()

    sent = next(c for c in calls if c["concert_name"].startswith("PF_BLOG_SEND"))
    assert sent["emotion"] == "음향이 좋았다."
    assert sent["artist_name"] == ["테스트아티스트"]
    assert sent["venue"] == "테스트공연장"
    assert sent["concert_date"] == "2030-06-01"
    # 예상 셋리는 안 부른 곡이 글에 들어갈 수 있어서 안 보냄
    assert sent["setlist"] == ["실제곡1", "실제곡2"]

    body = (await _get_draft(ticket_id, token)).json()
    assert body["status"] == "done"
    assert body["title"] == sent["concert_name"]
    assert body["body"] == "음향이 좋았다."
    assert body["text"] == f"{sent['concert_name']}\n\n음향이 좋았다."
    assert body["generated_at"] is not None


@pytest.mark.asyncio
async def test_send_without_real_setlist_sends_empty_setlist():
    token, _, ticket_id = await _ticket("PF_BLOG_NOSET")
    await _post_draft(ticket_id, token)

    calls: list[dict] = []
    with _blog_url(), _llm_client(calls):
        await send_blog_drafts_to_llm()

    sent = next(c for c in calls if c["concert_name"].startswith("PF_BLOG_NOSET"))
    assert sent["setlist"] == []


@pytest.mark.asyncio
async def test_send_failure_retries_until_limit_then_failed():
    token, _, ticket_id = await _ticket("PF_BLOG_FAIL")
    await _post_draft(ticket_id, token)

    for _ in range(3):
        with _blog_url(), _llm_client([], fail=True):
            await send_blog_drafts_to_llm()
    assert (await _get_draft(ticket_id, token)).json()["status"] == "failed"

    # 실패로 확정된 건 더 안 보냄
    calls: list[dict] = []
    with _blog_url(), _llm_client(calls):
        await send_blog_drafts_to_llm()
    assert not any(c["concert_name"].startswith("PF_BLOG_FAIL") for c in calls)

    # 다시 요청하면 처음부터
    assert (await _post_draft(ticket_id, token)).json()["status"] == "pending"


@pytest.mark.asyncio
async def test_rerequest_during_generation_discards_old_result():
    token, _, ticket_id = await _ticket("PF_BLOG_RACE")
    await _post_draft(ticket_id, token, emotion="옛 글.")

    async def _post(url, json=None, headers=None):
        # 생성하는 사이 유저가 새 글로 다시 요청
        if json["concert_name"].startswith("PF_BLOG_RACE"):
            await _post_draft(ticket_id, token, emotion="새 글.")
        response = MagicMock()
        response.json.return_value = {"title": json["concert_name"], "body": json["emotion"], "text": ""}
        return response

    client = MagicMock()
    client.__aenter__ = AsyncMock(return_value=client)
    client.__aexit__ = AsyncMock(return_value=None)
    client.post = AsyncMock(side_effect=_post)
    with _blog_url(), patch("app.services.blog_draft.httpx.AsyncClient", return_value=client):
        await send_blog_drafts_to_llm()

    body = (await _get_draft(ticket_id, token)).json()
    assert body["status"] == "pending"
    assert body["emotion"] == "새 글."
    async with AsyncSessionLocal() as db:
        draft = (await db.execute(select(BlogDraft).where(BlogDraft.ticket_id == uuid.UUID(ticket_id)))).scalar_one()
    assert draft.body is None


@pytest.mark.asyncio
async def test_send_skipped_without_blog_url():
    with patch("app.services.blog_draft.settings.LLM_BLOG_URL", ""):
        assert await send_blog_drafts_to_llm() == 0
