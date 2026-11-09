import uuid
from datetime import date, timedelta, timezone
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from app.core.database import AsyncSessionLocal
from app.main import app
from app.models.blog_draft import BlogDraft
from app.models.concert import Concert, EventType
from app.models.notification import Notification, NotificationType
from app.models.setlist import PreSetlist, RealSetlist
from app.models.ticket import Ticket
from app.services.blog_draft import _MAX_ATTEMPTS, send_blog_drafts_to_llm
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


async def _put_text(ticket_id: str, token: str, text: str):
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        return await ac.put(
            f"/api/v1/tickets/{ticket_id}/blog-draft/text",
            json={"text": text},
            headers={"Authorization": f"Bearer {token}"},
        )


async def _load(ticket_id: str) -> BlogDraft:
    async with AsyncSessionLocal() as db:
        return (await db.execute(select(BlogDraft).where(BlogDraft.ticket_id == uuid.UUID(ticket_id)))).scalar_one()


# 배치는 마지막 수정 뒤 자정이 지난 메모만 정리해서, 메모를 어제 고친 것으로 돌려둠
async def _backdate(ticket_id: str) -> None:
    async with AsyncSessionLocal() as db:
        draft = (await db.execute(select(BlogDraft).where(BlogDraft.ticket_id == uuid.UUID(ticket_id)))).scalar_one()
        draft.requested_at -= timedelta(days=1)
        await db.commit()


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
async def test_festival_draft_sends_without_setlist():
    token, concert_id, ticket_id = await _ticket("PF_BLOG_FEST")
    async with AsyncSessionLocal() as db:
        concert = await db.get(Concert, uuid.UUID(concert_id))
        concert.event_type = EventType.FESTIVAL.value
        db.add(RealSetlist(concert_id=uuid.UUID(concert_id), performance_date=date(2030, 6, 1),
                           songs=[{"name": "실제곡1"}]))
        await db.commit()

    assert (await _post_draft(ticket_id, token)).status_code == 202
    await _backdate(ticket_id)

    calls: list[dict] = []
    with _blog_url(), _llm_client(calls):
        await send_blog_drafts_to_llm()

    sent = next(c for c in calls if c["concert_name"].startswith("PF_BLOG_FEST"))
    # 페스티벌은 실제 셋리가 있어도 안 보냄
    assert sent["setlist"] == []
    assert (await _get_draft(ticket_id, token)).json()["status"] == "done"


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
    await _backdate(ticket_id)

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
    await _backdate(ticket_id)

    calls: list[dict] = []
    with _blog_url(), _llm_client(calls):
        await send_blog_drafts_to_llm()

    sent = next(c for c in calls if c["concert_name"].startswith("PF_BLOG_NOSET"))
    assert sent["setlist"] == []


async def _set_photos(ticket_id: str, page_layout: dict | None, photo_urls: list[str] | None = None) -> None:
    async with AsyncSessionLocal() as db:
        ticket = await db.get(Ticket, uuid.UUID(ticket_id))
        ticket.page_layout = page_layout
        ticket.concert_photo_urls = photo_urls
        await db.commit()


def _photo_item(item_id: str, url: str, z: int, taken_at: str | None = None) -> dict:
    photo = {"w": 300, "h": 400, **({"taken_at": taken_at} if taken_at else {})}
    return {"id": item_id, "type": "photo", "ref": url, "cx": 0.5, "cy": 0.5, "w": 0.4, "rot": 0, "z": z, "photo": photo}


@pytest.mark.asyncio
async def test_send_includes_page_photos_in_added_order():
    # 겹침 순서(z)와 상관없이 옮겨 온 예전 사진(legacyN) → 추가 시각 순서, 둘 다 아닌 id는 맨 뒤
    token, _, ticket_id = await _ticket("PF_BLOG_LAYOUT")
    old = "p" + _base36(1_700_000_000_000_000) + "0"
    new = "p" + _base36(1_700_000_000_500_000) + "1"
    await _set_photos(
        ticket_id,
        {
            "version": 1,
            "canvas_aspect": 1.5,
            "items": [
                {"id": "poster", "type": "poster", "cx": 0.5, "cy": 0.5, "w": 0.5, "rot": 0, "z": 0},
                _photo_item(new, "https://img.test/new.jpg", 1),
                _photo_item("x1", "https://img.test/unknown.jpg", 2),
                _photo_item(old, "https://img.test/old.jpg", 3, taken_at="2026:11:06 19:30:00"),
                _photo_item("legacy1", "https://img.test/legacy1.jpg", 4),
                _photo_item("legacy0", "https://img.test/legacy0.jpg", 5),
            ],
        },
    )
    # 배치가 없는 예전 티켓은 concert_photo_urls 그대로
    legacy_token, _, legacy_ticket_id = await _ticket("PF_BLOG_LEGACY")
    await _set_photos(legacy_ticket_id, None, ["https://img.test/a.jpg", "https://img.test/b.jpg"])
    for tok, tid in ((token, ticket_id), (legacy_token, legacy_ticket_id)):
        await _post_draft(tid, tok)
        await _backdate(tid)

    calls: list[dict] = []
    with _blog_url(), _llm_client(calls):
        await send_blog_drafts_to_llm()

    sent = next(c for c in calls if c["concert_name"].startswith("PF_BLOG_LAYOUT"))
    assert sent["photos"] == [
        {"url": "https://img.test/legacy0.jpg"},
        {"url": "https://img.test/legacy1.jpg"},
        {"url": "https://img.test/old.jpg", "taken_at": "2026:11:06 19:30:00"},
        {"url": "https://img.test/new.jpg"},
        {"url": "https://img.test/unknown.jpg"},
    ]
    legacy = next(c for c in calls if c["concert_name"].startswith("PF_BLOG_LEGACY"))
    assert legacy["photos"] == [{"url": "https://img.test/a.jpg"}, {"url": "https://img.test/b.jpg"}]


def _base36(n: int) -> str:
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    out = ""
    while n:
        n, r = divmod(n, 36)
        out = digits[r] + out
    return out


@pytest.mark.asyncio
async def test_send_failure_retries_until_limit_then_failed():
    token, _, ticket_id = await _ticket("PF_BLOG_FAIL")
    await _post_draft(ticket_id, token)
    await _backdate(ticket_id)

    for _ in range(_MAX_ATTEMPTS):
        with _blog_url(), _llm_client([], fail=True):
            await send_blog_drafts_to_llm()
    assert (await _get_draft(ticket_id, token)).json()["status"] == "failed"

    # 실패로 확정된 건 더 안 보냄
    calls: list[dict] = []
    with _blog_url(), _llm_client(calls):
        await send_blog_drafts_to_llm()
    assert not any(c["concert_name"].startswith("PF_BLOG_FAIL") for c in calls)

    # 같은 메모로 다시 보내면 "다시 정리" - 시도 횟수만 초기화하고 그날 밤 다시 보냄
    assert (await _post_draft(ticket_id, token)).json()["status"] == "pending"
    calls = []
    with _blog_url(), _llm_client(calls):
        await send_blog_drafts_to_llm()
    assert any(c["concert_name"].startswith("PF_BLOG_FAIL") for c in calls)
    assert (await _get_draft(ticket_id, token)).json()["status"] == "done"


@pytest.mark.asyncio
async def test_rerequest_during_generation_discards_old_result():
    token, _, ticket_id = await _ticket("PF_BLOG_RACE")
    await _post_draft(ticket_id, token, emotion="옛 글.")
    await _backdate(ticket_id)

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
    assert (await _load(ticket_id)).body is None


@pytest.mark.asyncio
async def test_send_skipped_without_blog_url():
    with patch("app.services.blog_draft.settings.LLM_BLOG_URL", ""):
        assert await send_blog_drafts_to_llm() == 0


# 자정 마감·정리본 유지

@pytest.mark.asyncio
async def test_memo_edited_today_waits_until_after_midnight():
    token, _, ticket_id = await _ticket("PF_BLOG_TODAY")
    await _post_draft(ticket_id, token)

    calls: list[dict] = []
    with _blog_url(), _llm_client(calls):
        await send_blog_drafts_to_llm()
    assert not any(c["concert_name"].startswith("PF_BLOG_TODAY") for c in calls)
    assert (await _get_draft(ticket_id, token)).json()["status"] == "pending"


@pytest.mark.asyncio
async def test_editing_memo_keeps_previous_draft_until_regenerated():
    token, _, ticket_id = await _ticket("PF_BLOG_STALE")
    await _post_draft(ticket_id, token, emotion="첫 메모.")
    await _backdate(ticket_id)
    with _blog_url(), _llm_client([]):
        await send_blog_drafts_to_llm()

    # 메모를 고쳐도 이전 정리본은 그대로 내려감
    body = (await _post_draft(ticket_id, token, emotion="고친 메모.")).json()
    assert body["status"] == "stale"
    assert body["body"] == "첫 메모."
    assert body["text"].endswith("첫 메모.")

    # 원래 메모로 되돌리면 다시 done
    assert (await _post_draft(ticket_id, token, emotion="첫 메모.")).json()["status"] == "done"
    assert (await _post_draft(ticket_id, token, emotion="고친 메모.")).json()["status"] == "stale"

    # 같은 내용을 다시 보내면 수정 시각이 안 바뀜(자정 마감이 미뤄지지 않음)
    requested_at = (await _load(ticket_id)).requested_at
    await _post_draft(ticket_id, token, emotion="고친 메모.")
    assert (await _load(ticket_id)).requested_at == requested_at

    await _put_text(ticket_id, token, "앱에서 고친 글")
    await _backdate(ticket_id)
    with _blog_url(), _llm_client([]):
        await send_blog_drafts_to_llm()

    # 새 정리본이 이전 정리본과 앱에서 고친 글을 덮어씀
    body = (await _get_draft(ticket_id, token)).json()
    assert body["status"] == "done"
    assert body["body"] == "고친 메모."
    assert body["edited"] is False
    assert body["text"].endswith("고친 메모.")


# 앱에서 고친 정리본

@pytest.mark.asyncio
async def test_save_edited_text():
    token, _, ticket_id = await _ticket("PF_BLOG_EDIT")
    await _post_draft(ticket_id, token)

    # 정리본이 없으면 고칠 게 없음
    assert (await _put_text(ticket_id, token, "고친 글")).status_code == 409

    await _backdate(ticket_id)
    with _blog_url(), _llm_client([]):
        await send_blog_drafts_to_llm()
    original = (await _get_draft(ticket_id, token)).json()["text"]

    res = await _put_text(ticket_id, token, "고친 글")
    assert res.status_code == 200
    assert res.json()["text"] == "고친 글"
    assert res.json()["edited"] is True
    assert res.json()["body"] != "고친 글"
    assert (await _get_draft(ticket_id, token)).json()["text"] == "고친 글"

    # 원래 글과 같아지면 고친 기록을 지움
    assert (await _put_text(ticket_id, token, original)).json()["edited"] is False

    other_token = await _get_token()
    assert (await _put_text(ticket_id, other_token, "남의 글")).status_code == 404


# 완료 알림

async def _blog_notifications(ticket_id: str) -> list[Notification]:
    async with AsyncSessionLocal() as db:
        user_id = (await db.get(Ticket, uuid.UUID(ticket_id))).user_id
        result = await db.execute(
            select(Notification).where(Notification.user_id == user_id, Notification.type == NotificationType.BLOG_DRAFT)
        )
        return list(result.scalars().all())


@pytest.mark.skip(reason="감상 메모 정리 완료 알림 끔")
@pytest.mark.asyncio
async def test_done_drafts_bundled_into_one_9am_notification_per_user():
    token = await _get_token()
    ticket_ids = []
    for name in ("PF_BLOG_NOTI_A", "PF_BLOG_NOTI_B"):
        concert_id = await _create_concert(f"{name}_{uuid.uuid4().hex[:6]}", token)
        ticket_ids.append(await _create_ticket(concert_id, token))
    single_token, _, single_ticket_id = await _ticket("PF_BLOG_NOTI_ONE")
    for tok, ticket_id in ((token, ticket_ids[0]), (token, ticket_ids[1]), (single_token, single_ticket_id)):
        await _post_draft(ticket_id, tok)
        await _backdate(ticket_id)

    with _blog_url(), _llm_client([]):
        await send_blog_drafts_to_llm()

    bundled = await _blog_notifications(ticket_ids[0])
    assert len(bundled) == 1
    assert bundled[0].title == "감상 메모 2개가 글로 정리됐어요"
    assert bundled[0].ticket_id is None
    scheduled = bundled[0].scheduled_at.astimezone(timezone(timedelta(hours=9)))
    assert (scheduled.hour, scheduled.minute) == (9, 0)

    single = await _blog_notifications(single_ticket_id)
    assert len(single) == 1
    assert single[0].title.startswith("PF_BLOG_NOTI_ONE")
    assert single[0].body == "감상 메모가 글로 정리됐어요."
    assert str(single[0].ticket_id) == single_ticket_id
    # 유저에게 보이는 알림 문구엔 "블로그"를 안 씀
    assert all("블로그" not in n.title + n.body for n in bundled + single)


async def _patch_settings(token: str, notification_settings: dict):
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        return await ac.patch(
            "/api/v1/settings",
            json={"notification_settings": notification_settings},
            headers={"Authorization": f"Bearer {token}"},
        )


@pytest.mark.skip(reason="감상 메모 정리 완료 알림 끔")
@pytest.mark.asyncio
async def test_blog_draft_notification_setting():
    # 꺼두면 정리는 되지만 알림은 안 생김
    off_token, _, off_ticket_id = await _ticket("PF_BLOG_NOTI_OFF")
    res = await _patch_settings(off_token, {"blog_draft": False})
    assert res.json()["notification_settings"]["blog_draft"] is False
    await _post_draft(off_ticket_id, off_token)
    await _backdate(off_ticket_id)

    # 켜둔 상태로 예약된 알림은 끄는 순간 취소됨
    on_token, _, on_ticket_id = await _ticket("PF_BLOG_NOTI_CANCEL")
    await _post_draft(on_ticket_id, on_token)
    await _backdate(on_ticket_id)

    with _blog_url(), _llm_client([]):
        await send_blog_drafts_to_llm()

    assert (await _get_draft(off_ticket_id, off_token)).json()["status"] == "done"
    assert await _blog_notifications(off_ticket_id) == []
    assert len(await _blog_notifications(on_ticket_id)) == 1

    await _patch_settings(on_token, {"blog_draft": False})
    assert await _blog_notifications(on_ticket_id) == []
