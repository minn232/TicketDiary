from pydantic import BaseModel
from uuid import UUID


class TimeTableEntry(BaseModel):
    # 타임테이블 단일 항목 (예: {"time": "17:00", "description": "입장"})
    time: str
    description: str


class TimeTableUpdate(BaseModel):
    # 타임테이블 upsert 요청
    contents: list[TimeTableEntry]


class TimeTableResponse(BaseModel):
    model_config = {"from_attributes": True}

    # 타임테이블 조회 응답
    id: UUID
    concert_id: UUID
    contents: list[TimeTableEntry]
