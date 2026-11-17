from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


class BlogDraftCreate(BaseModel):
    # 유저가 자유롭게 쓴 감상 글 - LLM 서버의 BlogDraftRequest.emotion과 같은 길이 제한
    emotion: str = Field(min_length=1, max_length=2000)


class BlogDraftTextUpdate(BaseModel):
    # 앱에서 고친 정리본(제목+본문 합친 글) - 원래 정리본과 같으면 고친 기록을 지움
    text: str = Field(min_length=1, max_length=10000)


class BlogDraftResponse(BaseModel):
    # none: 메모 없음, pending: 첫 정리 대기, done: 지금 메모로 정리됨,
    # stale: 메모를 고쳐서 다시 정리 대기(이전 정리본은 그대로 내려감), failed: 여러 번 실패해서 더 안 보냄
    status: Literal["none", "pending", "done", "stale", "failed"]
    emotion: str | None = None
    # 정리본 - done이 아니어도 이전에 정리된 게 있으면 내려감
    title: str | None = None
    body: str | None = None
    # 블로그 에디터에 한 번에 붙여넣을 글 - 앱에서 고친 게 있으면 그것, 없으면 제목+본문
    text: str | None = None
    edited: bool = False
    requested_at: datetime | None = None
    generated_at: datetime | None = None


class LlmBlogDraftResultRequest(BaseModel):
    # LLM 서버 콜백 바디 - emotion은 받은 감상 글 그대로(그 사이 메모가 바뀌었으면 버리는 데 씀).
    # 성공이면 title+body, 실패면 error
    emotion: str
    title: str | None = None
    body: str | None = None
    error: str | None = None


class LlmBlogDraftResultResponse(BaseModel):
    saved: bool
