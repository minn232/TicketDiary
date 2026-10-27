from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


class BlogDraftCreate(BaseModel):
    # 유저가 자유롭게 쓴 감상 글 - LLM 서버의 BlogDraftRequest.emotion과 같은 길이 제한
    emotion: str = Field(min_length=1, max_length=2000)


class BlogDraftResponse(BaseModel):
    # none: 요청한 적 없음, pending: 밤 배치 생성 대기, done: 생성 완료, failed: 여러 번 실패해서 더 안 보냄
    status: Literal["none", "pending", "done", "failed"]
    emotion: str | None = None
    title: str | None = None
    body: str | None = None
    # 블로그 에디터에 한 번에 붙여넣을 수 있게 제목+본문을 합친 것(LLM 응답의 text와 같은 형식)
    text: str | None = None
    requested_at: datetime | None = None
    generated_at: datetime | None = None


class LlmBlogDraftResult(BaseModel):
    # LLM 서버 POST /blog-draft 응답 - text는 제목+본문을 합친 것이라 저장하지 않음
    title: str
    body: str
