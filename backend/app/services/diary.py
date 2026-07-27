import logging

import httpx
from sqlalchemy import select
from sqlalchemy.orm import selectinload

from app.core.config import settings
from app.core.database import AsyncSessionLocal
from app.models.ticket import Ticket

logger = logging.getLogger(__name__)


# 자정 배치: 일기 생성 요청된(diary_requested_at is not null) 아직 미완료(diary is null) 티켓들을
# LLM팀 웹훅으로 전송. LLM팀 서버가 KST 00시~01시 사이 한정된 시간에만 떠있어서, 요청 즉시
# 동기 호출하던 이전 방식(30초 타임아웃) 대신 크롤링/아티스트 추출과 동일하게 배치+웹훅 방식으로 전환함.
# 결과는 POST /tickets/{ticket_id}/diary-result 웹훅으로 나중에 수신
async def send_diary_requests_to_llm() -> None:
    if not settings.LLM_DIARY_URL:
        logger.info("LLM_DIARY_URL 미설정, 전송 건너뜀")
        return

    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(Ticket)
            .options(selectinload(Ticket.concert))
            .where(Ticket.diary_requested_at.isnot(None), Ticket.diary.is_(None))
        )
        tickets = list(result.scalars().all())

    if not tickets:
        logger.info("전송할 일기 생성 요청 없음")
        return

    payload = [
        {
            "ticket_id": str(t.id),
            "review": t.review,
            "concert_name": t.concert.name if t.concert else None,
            "artist_name": t.concert.artist_name if t.concert else [],
            "venue": t.concert.venue if t.concert else None,
            "concert_date": t.concert.start_date.date().isoformat() if t.concert else None,
        }
        for t in tickets
    ]

    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(
                settings.LLM_DIARY_URL,
                json=payload,
                headers={"Authorization": f"Bearer {settings.LLM_EXTRACT_API_KEY}"},
            )
            response.raise_for_status()
        logger.info(f"LLM팀 일기 생성 요청 전송 완료: {len(tickets)}건")
    except Exception as e:
        logger.error(f"LLM팀 일기 생성 요청 전송 실패: {e}")
