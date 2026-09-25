import uuid
from datetime import datetime, timezone

from sqlalchemy import Boolean, Column, DateTime, ForeignKey, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID

from app.core.database import Base


# 공연 하나에서 아티스트 표기가 가리키는 canonical - 전역 별칭(ArtistAlias)보다 우선. 같은 이름이
# 공연마다 다른 사람일 수 있어서(동명이인) 유저/관리자가 "이 공연의 ○○는 이 사람"으로 고친 값 -
# canonical_id가 NULL이면 "연결할 아티스트 없음"으로 확정한 것
class ConcertArtistLink(Base):
    __tablename__ = "concert_artist_links"
    __table_args__ = (UniqueConstraint("concert_id", "artist_text", name="uq_concert_artist_link"),)

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    concert_id = Column(UUID(as_uuid=True), ForeignKey("concerts.id", ondelete="CASCADE"), nullable=False)
    artist_text = Column(String, nullable=False)
    canonical_id = Column(
        UUID(as_uuid=True), ForeignKey("canonical_artists.id", ondelete="CASCADE"), nullable=True
    )
    updated_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))


# 공연별 아티스트 연결 변경 기록 - 바로 적용하는 대신 관리자가 보고 되돌릴 수 있게 남김 -
# before_was_link=False면 변경 전엔 공연별 연결 없이 전역 별칭으로 찾던 상태(되돌리면 연결 삭제)
class ArtistIdentityChange(Base):
    __tablename__ = "artist_identity_changes"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    concert_id = Column(UUID(as_uuid=True), ForeignKey("concerts.id", ondelete="CASCADE"), nullable=False)
    artist_text = Column(String, nullable=False)
    before_canonical_id = Column(
        UUID(as_uuid=True), ForeignKey("canonical_artists.id", ondelete="SET NULL"), nullable=True
    )
    before_was_link = Column(Boolean, nullable=False, default=False)
    after_canonical_id = Column(
        UUID(as_uuid=True), ForeignKey("canonical_artists.id", ondelete="SET NULL"), nullable=True
    )
    changed_by_user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), nullable=True)
    # "user"(앱) | "admin"(관리자 페이지)
    source = Column(String, nullable=False)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
    reverted_at = Column(DateTime(timezone=True), nullable=True)
