from sqlalchemy import Column, DateTime, Integer, String, text

from app.core.database import Base


# 밤배치 LLM 작업 진행상황을 추적하는 싱글턴 로우(row 1개, id는 항상 "singleton") - pod 조기
# 정지 판단용. ①정확한 건수 매칭(pending_count 0이 되는 즉시 웹훅에서 정지) ②유휴시간(①이
# 안 될 때 안전망). early_stopped_at은 같은 밤 중복 정지 트리거 방지 표시.
class LlmNightBatchState(Base):
    __tablename__ = "llm_night_batch_state"

    id = Column(String, primary_key=True, default="singleton")
    last_send_at = Column(DateTime(timezone=True), nullable=True)
    last_callback_at = Column(DateTime(timezone=True), nullable=True)
    early_stopped_at = Column(DateTime(timezone=True), nullable=True)
    # 그날 밤 전송 배치 3개(크롤링/아티스트추출/일기)가 전부 끝난 시각(diary_send가 항상
    # 마지막). 이게 없으면 pending_count가 우연히 0이어도 아직 남은 배치가 있을 수 있어 완료로 안 봄
    all_sent_at = Column(DateTime(timezone=True), nullable=True)
    # 그날 밤 보낸 건수 - 콜백 받은 건수. 음수로 내려가지 않게 클램프(중복 콜백 방어)
    pending_count = Column(Integer, nullable=False, default=0, server_default=text("0"))
