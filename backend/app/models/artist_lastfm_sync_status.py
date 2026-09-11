import uuid
from datetime import datetime, timezone

from sqlalchemy import Column, DateTime, Integer, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID

from app.core.database import Base


# Last.fm이 결과를 못 준(빈 응답) 아티스트의 재시도 기록 - artist_similarities/artist_genres는
# 성공 결과만 저장하는 캐시라서, 실패는 여기 따로 남겨 crawl_attempted_at류와 동일하게
# 쿨다운+상한 재시도를 적용한다. 안 그러면 Last.fm이 못 찾는 이름이 매일 밤 영원히 재시도됨
# (실측 1800~2270건 누적 확인, lastfm.py의 _filter_lastfm_retry_eligible 참고)
class ArtistLastfmSyncStatus(Base):
    __tablename__ = "artist_lastfm_sync_status"

    __table_args__ = (
        UniqueConstraint("artist_name", "sync_type", name="uq_artist_lastfm_sync_status_name_type"),
    )

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    artist_name = Column(String, nullable=False, index=True)
    # "similarity"(getSimilar) | "genre"(getTopTags) - 같은 아티스트라도 둘 중 하나만 실패할 수
    # 있어(예: 유사아티스트는 없는데 태그는 있음) 별도 행으로 추적
    sync_type = Column(String, nullable=False)
    last_attempted_at = Column(
        DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc)
    )
    attempt_count = Column(Integer, nullable=False, default=1)
