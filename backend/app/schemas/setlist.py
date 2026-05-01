from pydantic import BaseModel
from uuid import UUID


class RealSetlistCreate(BaseModel):
    # 실제 셋리스트 생성 요청
    concert_id: UUID
    setlistfm_id: str | None = None
    songs: str
    is_user_edited: bool = False
    edited_user_nickname: str | None = None


class RealSetlistUpdate(BaseModel):
    # 실제 셋리스트 수정 요청
    songs: str | None = None
    is_user_edited: bool | None = None
    edited_user_nickname: str | None = None


class RealSetlistResponse(BaseModel):
    model_config = {"from_attributes": True}

    # 실제 셋리스트 조회 응답
    id: UUID
    concert_id: UUID
    setlistfm_id: str | None
    songs: str
    is_user_edited: bool
    edited_user_nickname: str | None


class PreSetlistCreate(BaseModel):
    # 예상 셋리스트 생성 요청
    concert_id: UUID
    setlistfm_id: str | None = None
    songs: str
    is_user_edited: bool = False
    edited_user_nickname: str | None = None


class PreSetlistUpdate(BaseModel):
    # 예상 셋리스트 수정 요청
    songs: str | None = None
    is_user_edited: bool | None = None
    edited_user_nickname: str | None = None


class PreSetlistResponse(BaseModel):
    model_config = {"from_attributes": True}

    # 예상 셋리스트 조회 응답
    id: UUID
    concert_id: UUID
    setlistfm_id: str | None
    songs: str
    is_user_edited: bool
    edited_user_nickname: str | None
