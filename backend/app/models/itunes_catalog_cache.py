import uuid
from datetime import datetime, timezone

from sqlalchemy import Column, DateTime, String
from sqlalchemy.dialects.postgresql import JSONB, UUID

from app.core.database import Base


# iTunes 아티스트별 곡 목록(미리듣기 URL 포함) 캐시 - 티켓을 열 때마다 iTunes를 부르면 분당
# 제한(약 20회)에 걸려서 7일간 재사용함. 조회 실패는 캐싱하지 않음(못 받은 걸 "곡 없음"으로
# 굳히지 않으려고)
class ItunesCatalogCache(Base):
    __tablename__ = "itunes_catalog_cache"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    itunes_artist_id = Column(String, nullable=False, unique=True)
    # [{track_id, us_name, kr_name, preview_url, track_view_url}] - us 스토어 순서(인기순에 가까움)
    tracks = Column(JSONB, nullable=False)
    fetched_at = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
