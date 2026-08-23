from pydantic import BaseModel


class DiaryResultRequest(BaseModel):
    # LLM팀이 생성한 일기 텍스트
    diary: str


class DiaryResultResponse(BaseModel):
    # 저장된 일기 텍스트 응답
    diary: str
