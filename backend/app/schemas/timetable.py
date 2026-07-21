from pydantic import BaseModel
from uuid import UUID


class TimeTableEntry(BaseModel):
    # 타임테이블 단일 항목. LLM팀 크롤링 추출 결과 원본 포맷 그대로 사용
    # (예: {"date": "2023-09-07", "time": null, "stage": "TOUCH", "event": "N.Flying 16:20 - 17:20 (60)"})
    # date/time/stage는 페스티벌 등에서 정보가 없으면 null일 수 있고, 시간 정보가 time이 아니라
    # event 텍스트 안에 포함되는 경우가 많음 (VLM 추출 특성상 time을 항상 분리해내지 못함)
    date: str | None = None
    time: str | None = None
    stage: str | None = None
    event: str


class TimeTableUpdate(BaseModel):
    # 타임테이블 upsert 요청
    contents: list[TimeTableEntry]


class TimeTableResponse(BaseModel):
    model_config = {"from_attributes": True}

    # 타임테이블 조회 응답
    id: UUID
    concert_id: UUID
    contents: list[TimeTableEntry]
