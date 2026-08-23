import uuid
from sqlalchemy import Column, String, Date, ForeignKey, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship
from app.core.database import Base


# 페스티벌 등 여러 날짜에 걸친 공연에서 "이 아티스트가 구체적으로 어느 날 출연하는지" 매핑.
# Concert.artist_name(날짜 구분 없는 플랫 배열)만으로는 날짜별 셋리스트 필터링이 안 돼서
# 별도로 둠 - LLM팀 크롤링(/crawl-result)·포스터 추출(/artist-result) 웹훅의
# lineup[].performance_date로 채워짐(app/services/lineup.py 참고). 이 테이블에 배정이 없는
# (concert_id, date) 조합은 "모른다"는 뜻이라, 서빙 쪽(setlist.py/pre_setlist.py)이 항상
# 전체 아티스트로 폴백함 - 값이 없다고 아무도 출연 안 한다는 뜻이 아님.
class ConcertLineup(Base):
    __tablename__ = "concert_lineups"

    # 같은 아티스트가 여러 날 출연하는 경우가 실제로 흔해서(예: 페스티벌 헤드라이너가 2일차
    # 모두 등장) concert_id+artist가 아니라 날짜까지 포함해서 유일하게 잡음
    __table_args__ = (
        UniqueConstraint("concert_id", "artist", "performance_date", name="uq_concert_lineup_artist_date"),
    )

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    concert_id = Column(UUID(as_uuid=True), ForeignKey("concerts.id"), nullable=False)
    # Concert.artist_name 배열에 들어가는 표기와 동일해야 함(서빙 시 문자열로 매칭) -
    # app/services/lineup.py의 upsert_concert_lineup이 저장 전에 정규화해서 맞춰줌
    artist = Column(String, nullable=False)
    performance_date = Column(Date, nullable=False)
    # 이 배정을 어느 파이프라인이 확인했는지 - "crawl"(예매처 상세페이지 크롤링) |
    # "poster"(티켓 등록 시 포스터 추출). 크롤링이 더 신뢰도 높다고 보고 병합 우선순위로 씀
    source = Column(String, nullable=False)

    concert = relationship("Concert", back_populates="lineups")
