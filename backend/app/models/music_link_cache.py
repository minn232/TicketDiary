import uuid
from datetime import datetime, timezone

from sqlalchemy import Column, DateTime, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID

from app.core.database import Base


# 셋리스트 곡 원탭 연결(music_resolve.py) 결과 캐시 - 매번 실제 API를 부르면 유튜브 쿼터를 쉽게 소진해
# (테스트 트래픽만으로 429) 같은 (service, artist, song)은 결과를 재사용함. resolved_url이 null이면
# "확인했는데 못 찾음" - 나중에 발매/업로드될 수 있어 이건 짧은 쿨다운으로만 캐싱(music_links.py)
class MusicLinkCache(Base):
    __tablename__ = "music_link_cache"

    __table_args__ = (
        UniqueConstraint("service", "artist", "song", name="uq_music_link_cache_service_artist_song"),
    )

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    service = Column(String, nullable=False)
    # artist가 없는 조회도 캐싱해야 해서 NULL 대신 빈 문자열로 통일 - NULL은 유니크 제약에서
    # 서로 다른 값 취급이라 NULL을 쓰면 같은 조합이 계속 중복 저장됨
    artist = Column(String, nullable=False, default="")
    song = Column(String, nullable=False)
    resolved_url = Column(String, nullable=True)
    resolved_at = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
