import uuid

from sqlalchemy import Column, String, Float, DateTime, func
from sqlalchemy.dialects.postgresql import UUID

from app.core.database import Base


# Last.fm artist.getSimilar 결과 캐시 (추천 요청마다 외부 API를 부르지 않기 위함)
# artist_name당 한 번만 배치로 채우고, 추천 계산은 이 테이블만 조회해서 실시간으로 함
class ArtistSimilarity(Base):
    __tablename__ = "artist_similarities"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    artist_name = Column(String, nullable=False, index=True)
    similar_artist_name = Column(String, nullable=False)
    match_score = Column(Float, nullable=False)
    fetched_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
