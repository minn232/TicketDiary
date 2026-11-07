import asyncio
import logging
from datetime import date, datetime, timedelta, timezone
from uuid import UUID

import httpx
from fastapi import HTTPException
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.config import settings
from app.core.database import AsyncSessionLocal
from app.core.http_errors import describe_http_error
from app.models.blog_draft import BlogDraft
from app.models.concert import EventType
from app.models.setlist import RealSetlist
from app.models.ticket import Ticket
from app.schemas.blog_draft import BlogDraftResponse, LlmBlogDraftResult
# 감상 메모 정리 완료 알림은 끔 - 정리본은 앱의 블로그 공유에서만 씀
# from app.services.notification import schedule_blog_draft_notifications
from app.services.ticket import get_ticket

logger = logging.getLogger(__name__)

# 같은 메모가 이만큼 실패하면 더 안 보냄(failed) - 앱에 "다시 정리" 버튼이 없어 밤마다 자동 재시도하고
# 일주일쯤 실패하면 멈춤. 메모를 고치거나 같은 메모로 다시 요청하면 0부터
_MAX_ATTEMPTS = 7
# LLM 서버 BLOG_DRAFT_CONCURRENCY와 맞춤 - 넘게 보내도 그쪽에서 대기할 뿐이라 이득 없음
_CONCURRENCY = 3
# 한 건 생성에 수십 초(모델 호출 2번) - 동시 3건이 LLM 쪽에서 대기하는 시간까지 감안
_REQUEST_TIMEOUT_SECONDS = 180.0
# LLM이 사진마다 시점 분류를 한 번씩 부름 - 생성 시간이 사진 수에 비례해 늘지 않게 상한
_MAX_PHOTOS = 20


_KST = timezone(timedelta(hours=9))


def _status(draft: BlogDraft | None) -> str:
    if draft is None:
        return "none"
    if draft.body is not None and draft.generated_from == draft.emotion:
        return "done"
    if draft.attempt_count >= _MAX_ATTEMPTS:
        return "failed"
    return "stale" if draft.body is not None else "pending"


# LLM 응답의 text와 같은 형식(제목+빈 줄+본문)
def _combined_text(draft: BlogDraft) -> str | None:
    if draft.body is None:
        return None
    return f"{draft.title}\n\n{draft.body}" if draft.title else draft.body


def _to_response(draft: BlogDraft | None) -> BlogDraftResponse:
    status = _status(draft)
    if draft is None:
        return BlogDraftResponse(status=status)
    return BlogDraftResponse(
        status=status,
        emotion=draft.emotion,
        title=draft.title,
        body=draft.body,
        text=draft.edited_text or _combined_text(draft),
        edited=draft.edited_text is not None,
        requested_at=draft.requested_at,
        generated_at=draft.generated_at if draft.body is not None else None,
    )


async def _find_draft(db: AsyncSession, ticket_id: UUID) -> BlogDraft | None:
    result = await db.execute(select(BlogDraft).where(BlogDraft.ticket_id == ticket_id))
    return result.scalar_one_or_none()


async def get_blog_draft(db: AsyncSession, user_id: UUID, ticket_id: UUID) -> BlogDraftResponse:
    await get_ticket(db, user_id, ticket_id)
    return _to_response(await _find_draft(db, ticket_id))


# 감상 메모만 저장하고 즉시 반환 - 정리는 마지막 수정 뒤 첫 자정이 지난 밤 LLM 배치가 함. 이전 정리본은
# 안 지우고 새 정리본이 나오면 덮어씀. 같은 내용이면 무시하되, failed면 시도 횟수만 초기화("다시 정리")
async def request_blog_draft(db: AsyncSession, user_id: UUID, ticket_id: UUID, emotion: str) -> BlogDraftResponse:
    ticket = await get_ticket(db, user_id, ticket_id)
    if ticket.concert is None:
        raise HTTPException(status_code=400, detail="공연 정보가 연결된 티켓만 블로그 글을 만들 수 있습니다.")

    emotion = emotion.strip()
    draft = await _find_draft(db, ticket_id)
    if draft is not None and draft.emotion == emotion:
        if _status(draft) == "failed":
            draft.attempt_count = 0
            draft.last_error = None
            await db.commit()
        return _to_response(draft)

    if draft is None:
        draft = BlogDraft(ticket_id=ticket_id)
        db.add(draft)
    draft.emotion = emotion
    draft.requested_at = datetime.now(timezone.utc)
    draft.attempt_count = 0
    draft.last_error = None
    await db.commit()
    return _to_response(draft)


# 앱에서 고친 정리본 저장 - 원래 정리본과 같아지면 고친 기록을 지움. 정리본이 아직 없으면 고칠 게 없음
async def save_blog_draft_text(db: AsyncSession, user_id: UUID, ticket_id: UUID, text: str) -> BlogDraftResponse:
    await get_ticket(db, user_id, ticket_id)
    draft = await _find_draft(db, ticket_id)
    if draft is None or draft.body is None:
        raise HTTPException(status_code=409, detail="아직 정리된 글이 없습니다.")

    draft.edited_text = None if text == _combined_text(draft) else text
    await db.commit()
    return _to_response(draft)


# 관람일 - 티켓에 찍힌 관람일, 없으면 하루짜리 공연의 시작일. 여러 날 공연인데 관람일을 모르면 None
def _performance_date(ticket: Ticket) -> date | None:
    if ticket.attended_date is not None:
        return ticket.attended_date.date()
    concert = ticket.concert
    if concert.start_date.date() == concert.end_date.date():
        return concert.start_date.date()
    return None


# 사진을 올린 순서 키 - 앱 사진 id는 "legacy{n}"(concert_photo_urls n번째를 옮긴 것, 가장 먼저 올림) 또는
# "p" + 추가 시각(마이크로초, 36진수 10자리) + 순번. 둘 다 아니면 저장 순서(index)대로 맨 뒤
def _photo_order_key(item: dict, index: int) -> tuple[int, int]:
    item_id = item.get("id") or ""
    if item_id.startswith("legacy") and item_id[6:].isdigit():
        return 0, int(item_id[6:])
    if item_id.startswith("p") and len(item_id) > 11:
        try:
            return 1, int(item_id[1:11], 36)
        except ValueError:
            pass
    return 2, index


# 공연후 페이지 사진(올린 순서) - page_layout은 겹침 순서라 id로 다시 정렬. 배치가 아직 없는 예전 티켓은
# concert_photo_urls. taken_at은 앱이 채운 경우만(없으면 LLM이 사진 EXIF에서 읽음)
def _ticket_photos(ticket: Ticket) -> list[dict]:
    items = [i for i in (ticket.page_layout or {}).get("items", []) if i.get("type") == "photo" and i.get("ref")]
    if not items:
        return [{"url": url} for url in (ticket.concert_photo_urls or [])[:_MAX_PHOTOS]]
    order = sorted(range(len(items)), key=lambda i: _photo_order_key(items[i], i))
    photos = []
    for i in order[:_MAX_PHOTOS]:
        taken_at = (items[i].get("photo") or {}).get("taken_at")
        photos.append({"url": items[i]["ref"], **({"taken_at": taken_at} if taken_at else {})})
    return photos


# LLM 요청 바디. 셋리는 그날 실제 셋리만 - 예상 셋리를 넣으면 "○○를 불러주었어요"처럼 안 부른
# 곡이 글에 들어갈 수 있어서 없으면 빈 목록. 페스티벌은 아티스트별 셋리 구성이 정해지지 않아
# 곡이 엉뚱한 아티스트에 붙을 수 있어서 안 보냄
async def _build_payload(db: AsyncSession, draft: BlogDraft, ticket: Ticket) -> dict:
    concert = ticket.concert
    performance_date = _performance_date(ticket)
    setlist: list[str] = []
    if performance_date is not None and concert.event_type != EventType.FESTIVAL.value:
        result = await db.execute(
            select(RealSetlist).where(
                RealSetlist.concert_id == concert.id, RealSetlist.performance_date == performance_date
            )
        )
        real = result.scalar_one_or_none()
        if real is not None:
            setlist = [s["name"] for s in real.songs or [] if s.get("name")]
    return {
        "emotion": draft.emotion,
        "concert_name": concert.name,
        "artist_name": concert.artist_name or [],
        "venue": concert.venue,
        "concert_date": (performance_date or concert.start_date.date()).isoformat(),
        "setlist": setlist,
        "photos": _ticket_photos(ticket),
    }


# 성공하면 알림용 (user_id, ticket_id, 공연명), 실패/건너뜀이면 None
async def _generate_one(
    client: httpx.AsyncClient, semaphore: asyncio.Semaphore, draft_id: UUID
) -> tuple[UUID, UUID, str] | None:
    async with semaphore, AsyncSessionLocal() as db:
        draft = await db.get(BlogDraft, draft_id)
        if draft is None:
            return None
        ticket = (
            await db.execute(select(Ticket).where(Ticket.id == draft.ticket_id).options(selectinload(Ticket.concert)))
        ).scalar_one_or_none()
        if ticket is None or ticket.concert is None:
            return None
        concert_name = ticket.concert.name
        requested_at = draft.requested_at
        payload = await _build_payload(db, draft, ticket)
        try:
            response = await client.post(
                settings.LLM_BLOG_URL,
                json=payload,
                headers={"Authorization": f"Bearer {settings.LLM_EXTRACT_API_KEY}"},
            )
            response.raise_for_status()
            result = LlmBlogDraftResult.model_validate(response.json())
        except Exception as e:
            await db.refresh(draft)
            if draft.requested_at == requested_at:
                draft.attempt_count += 1
                draft.last_error = describe_http_error(e)[:500]
                await db.commit()
            logger.error(f"[LLM] 블로그 초안 생성 실패 draft_id={draft_id}: {describe_http_error(e)}")
            return None

        # 생성하는 동안 유저가 메모를 고쳤으면(requested_at 바뀜) 옛 메모로 만든 결과라 버림
        await db.refresh(draft)
        if draft.requested_at != requested_at:
            return None
        draft.title = result.title
        draft.body = result.body
        draft.generated_from = payload["emotion"]
        draft.edited_text = None
        draft.generated_at = datetime.now(timezone.utc)
        await db.commit()
        return ticket.user_id, ticket.id, concert_name


# 마지막 수정 뒤 첫 자정(KST)이 지난 메모만 정리 - 공연 당일 밤에 적다 만 메모가 03시에 정리되지 않게
# 하고, 하루 기다리는 동안 실제 셋리가 들어올 확률도 오름
def _edit_cutoff(now: datetime) -> datetime:
    midnight = now.astimezone(_KST).replace(hour=0, minute=0, second=0, microsecond=0)
    return midnight.astimezone(timezone.utc)


# 밤 LLM 배치: 생성 대기 중인 초안을 LLM 서버 /blog-draft에 보내고 응답(초안)을 바로 저장. 다른
# 배치와 달리 콜백 없이 응답으로 받아서 전송 건수(pending_count)에 안 잡음 - 호출부가 이 함수가
# 끝난 뒤에 "전송 완료"를 찍어야 생성 도중 유휴로 판단돼 pod이 꺼지지 않음
async def send_blog_drafts_to_llm() -> int:
    if not settings.LLM_BLOG_URL:
        logger.info("LLM_BLOG_URL 미설정, 전송 건너뜀")
        return 0

    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(BlogDraft.id).where(
                or_(BlogDraft.generated_from.is_(None), BlogDraft.generated_from != BlogDraft.emotion),
                BlogDraft.attempt_count < _MAX_ATTEMPTS,
                BlogDraft.requested_at < _edit_cutoff(datetime.now(timezone.utc)),
            )
        )
        draft_ids = list(result.scalars().all())

    if not draft_ids:
        logger.info("[LLM] 생성할 블로그 초안 없음")
        return 0

    semaphore = asyncio.Semaphore(_CONCURRENCY)
    async with httpx.AsyncClient(timeout=_REQUEST_TIMEOUT_SECONDS) as client:
        results = await asyncio.gather(*(_generate_one(client, semaphore, i) for i in draft_ids))
    done = [r for r in results if r is not None]
    logger.info(f"[LLM] 블로그 초안 생성 완료: {len(done)}/{len(draft_ids)}건")
    # 완료 알림은 끔(위 import 참고)
    # if done:
    #     try:
    #         async with AsyncSessionLocal() as db:
    #             await schedule_blog_draft_notifications(db, done)
    #     except Exception:
    #         logger.exception("[LLM] 블로그 초안 완료 알림 예약 오류")
    return len(done)
