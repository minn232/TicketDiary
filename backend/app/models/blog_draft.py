import uuid

from sqlalchemy import Column, DateTime, ForeignKey, Integer, String, Text, text
from sqlalchemy.dialects.postgresql import UUID

from app.core.database import Base


# 티켓 하나의 블로그 글 초안(티켓당 1개, 다시 요청하면 덮어씀) - LLM pod이 밤 배치 때만 떠서 요청은
# 저장해두고 배치가 생성함. generated_at이 비었거나 requested_at보다 이전이면 생성 대기
class BlogDraft(Base):
    __tablename__ = "blog_drafts"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    ticket_id = Column(UUID(as_uuid=True), ForeignKey("tickets.id", ondelete="CASCADE"), nullable=False, unique=True)
    # 유저가 자유롭게 쓴 감상 글(LLM 요청의 emotion) - 한줄평(ticket.review)과는 별개로 받음
    emotion = Column(Text, nullable=False)
    title = Column(String, nullable=True)
    body = Column(Text, nullable=True)
    requested_at = Column(DateTime(timezone=True), nullable=False)
    generated_at = Column(DateTime(timezone=True), nullable=True)
    # 이번 요청의 생성 실패 횟수 - 다시 요청하면 0으로 초기화, 상한을 넘으면 배치가 더 안 보냄
    attempt_count = Column(Integer, nullable=False, default=0, server_default=text("0"))
    last_error = Column(String, nullable=True)
