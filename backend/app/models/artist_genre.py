import uuid

from sqlalchemy import Column, DateTime, String, func
from sqlalchemy.dialects.postgresql import UUID, ARRAY

from app.core.database import Base


# Last.fm artist.getTopTags 결과를 화이트리스트로 정규화한 장르 라벨 캐시.
# 아티스트 하나가 여러 장르(예: 힙합+K-pop)에 걸리는 게 자연스러워서 배열로 저장.
# genres가 None이면 "태그는 받아왔지만 화이트리스트에 걸리는 게 하나도 없었다"는 뜻으로,
# 이 경우도 한 행으로 캐싱해 매 배치마다 재조회하지 않음(artist_similarities와 동일 전략)
class ArtistGenre(Base):
    __tablename__ = "artist_genres"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    artist_name = Column(String, nullable=False, unique=True, index=True)
    genres = Column(ARRAY(String), nullable=True)
    # 주기적 재조회(TTL) 판단용 - lastfm.py의 _LASTFM_CACHE_TTL 참고. artist_similarities.fetched_at과 동일 용도
    fetched_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
