import asyncio
import logging
from datetime import date, datetime, timezone
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
from app.services.ticket import get_ticket

logger = logging.getLogger(__name__)

# 같은 요청이 이만큼 실패하면 더 안 보냄(failed) - 다시 요청하면 0부터
_MAX_ATTEMPTS = 3
# LLM 서버 BLOG_DRAFT_CONCURRENCY와 맞춤 - 넘게 보내도 그쪽에서 대기할 뿐이라 이득 없음
_CONCURRENCY = 3
# 한 건 생성에 수십 초(모델 호출 2번) - 동시 3건이 LLM 쪽에서 대기하는 시간까지 감안
_REQUEST_TIMEOUT_SECONDS = 180.0


def _status(draft: BlogDraft | None) -> str:
    if draft is None:
        return "none"
    if draft.generated_at is not None and draft.generated_at >= draft.requested_at:
        return "done"
    return "failed" if draft.attempt_count >= _MAX_ATTEMPTS else "pending"


def _to_response(draft: BlogDraft | None) -> BlogDraftResponse:
    status = _status(draft)
    if draft is None:
        return BlogDraftResponse(status=status)
    done = status == "done"
    title, body = (draft.title, draft.body) if done else (None, None)
    text = (f"{title}\n\n{body}" if title else body) if done else None
    return BlogDraftResponse(
        status=status,
        emotion=draft.emotion,
        title=title,
        body=body,
        text=text,
        requested_at=draft.requested_at,
        generated_at=draft.generated_at if done else None,
    )


async def _find_draft(db: AsyncSession, ticket_id: UUID) -> BlogDraft | None:
    result = await db.execute(select(BlogDraft).where(BlogDraft.ticket_id == ticket_id))
    return result.scalar_one_or_none()


async def get_blog_draft(db: AsyncSession, user_id: UUID, ticket_id: UUID) -> BlogDraftResponse:
    await get_ticket(db, user_id, ticket_id)
    return _to_response(await _find_draft(db, ticket_id))


# 감상 글만 저장하고 즉시 반환 - 실제 생성은 밤 LLM 배치(send_blog_drafts_to_llm)가 하고, 클라이언트는
# GET으로 status가 done이 되는지 확인함. 다시 요청하면 이전 초안을 지우고 새 글로 재생성 대기.
# 페스티벌은 아티스트별 셋리 구성이 정해지지 않아 일단 제외
async def request_blog_draft(db: AsyncSession, user_id: UUID, ticket_id: UUID, emotion: str) -> BlogDraftResponse:
    ticket = await get_ticket(db, user_id, ticket_id)
    if ticket.concert is None:
        raise HTTPException(status_code=400, detail="공연 정보가 연결된 티켓만 블로그 글을 만들 수 있습니다.")
    if ticket.concert.event_type == EventType.FESTIVAL.value:
        raise HTTPException(status_code=400, detail="페스티벌은 아직 블로그 글 생성을 지원하지 않습니다.")

    draft = await _find_draft(db, ticket_id)
    if draft is None:
        draft = BlogDraft(ticket_id=ticket_id)
        db.add(draft)
    draft.emotion = emotion.strip()
    draft.title = None
    draft.body = None
    draft.requested_at = datetime.now(timezone.utc)
    draft.generated_at = None
    draft.attempt_count = 0
    draft.last_error = None
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


# LLM 요청 바디. 셋리는 그날 실제 셋리만 - 예상 셋리를 넣으면 "○○를 불러주었어요"처럼 안 부른
# 곡이 글에 들어갈 수 있어서 없으면 빈 목록
async def _build_payload(db: AsyncSession, draft: BlogDraft, ticket: Ticket) -> dict:
    concert = ticket.concert
    performance_date = _performance_date(ticket)
    setlist: list[str] = []
    if performance_date is not None:
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
    }


async def _generate_one(client: httpx.AsyncClient, semaphore: asyncio.Semaphore, draft_id: UUID) -> bool:
    async with semaphore, AsyncSessionLocal() as db:
        draft = await db.get(BlogDraft, draft_id)
        if draft is None:
            return False
        ticket = (
            await db.execute(select(Ticket).where(Ticket.id == draft.ticket_id).options(selectinload(Ticket.concert)))
        ).scalar_one_or_none()
        if ticket is None or ticket.concert is None:
            return False
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
            return False

        # 생성하는 동안 유저가 다시 요청했으면(requested_at 바뀜) 옛 글로 만든 결과라 버림
        await db.refresh(draft)
        if draft.requested_at != requested_at:
            return False
        draft.title = result.title
        draft.body = result.body
        draft.generated_at = datetime.now(timezone.utc)
        await db.commit()
        return True


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
                or_(BlogDraft.generated_at.is_(None), BlogDraft.generated_at < BlogDraft.requested_at),
                BlogDraft.attempt_count < _MAX_ATTEMPTS,
            )
        )
        draft_ids = list(result.scalars().all())

    if not draft_ids:
        logger.info("[LLM] 생성할 블로그 초안 없음")
        return 0

    semaphore = asyncio.Semaphore(_CONCURRENCY)
    async with httpx.AsyncClient(timeout=_REQUEST_TIMEOUT_SECONDS) as client:
        results = await asyncio.gather(*(_generate_one(client, semaphore, i) for i in draft_ids))
    done = sum(results)
    logger.info(f"[LLM] 블로그 초안 생성 완료: {done}/{len(draft_ids)}건")
    return done
