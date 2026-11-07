import uuid

from sqlalchemy import Column, DateTime, ForeignKey, Integer, String, Text, text
from sqlalchemy.dialects.postgresql import UUID

from app.core.database import Base


# 티켓 하나의 블로그 글 초안(티켓당 1개) - LLM pod이 밤 배치 때만 떠서 메모는 저장해두고 배치가 정리함.
# 메모를 고쳐도 이전 정리본은 남기고, generated_from이 지금 메모와 다르면 다음 배치가 다시 정리
class BlogDraft(Base):
    __tablename__ = "blog_drafts"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    ticket_id = Column(UUID(as_uuid=True), ForeignKey("tickets.id", ondelete="CASCADE"), nullable=False, unique=True)
    # 유저가 자유롭게 쓴 감상 글(LLM 요청의 emotion) - 한줄평(ticket.review)과는 별개로 받음
    emotion = Column(Text, nullable=False)
    title = Column(String, nullable=True)
    body = Column(Text, nullable=True)
    # 지금 title/body를 만든 메모 원문
    generated_from = Column(Text, nullable=True)
    # 앱에서 고친 정리본(제목+본문 합친 글) - 새 정리본이 나오면 지움
    edited_text = Column(Text, nullable=True)
    # 메모를 마지막으로 고친 시각 - 이 시각 뒤 첫 자정(KST)이 지나야 배치가 정리함
    requested_at = Column(DateTime(timezone=True), nullable=False)
    generated_at = Column(DateTime(timezone=True), nullable=True)
    # 지금 메모의 정리 실패 횟수 - 메모를 고치거나 다시 정리하면 0, 상한을 넘으면 배치가 더 안 보냄
    attempt_count = Column(Integer, nullable=False, default=0, server_default=text("0"))
    last_error = Column(String, nullable=True)
