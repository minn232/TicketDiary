import uuid
from sqlalchemy import Column, String, ForeignKey, Boolean, DateTime, text, func
from sqlalchemy.dialects.postgresql import UUID, JSONB
from sqlalchemy.orm import relationship
from app.core.database import Base


"""
artists JSON 형식: [{"artist_name": "A", "kopis_artist_id": "1"}]
concerts JSON 형식: [{"concert_name": "A", "kopis_concert_id": "1"}]
"""
class ArtistFollow(Base):
    __tablename__ = "artist_follows"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=False, unique=True)
    artists = Column(JSONB, nullable=False, server_default=text("'[]'::jsonb"))


class ConcertFollow(Base):
    __tablename__ = "concert_follows"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=False, unique=True)
    concerts = Column(JSONB, nullable=False, server_default=text("'[]'::jsonb"))


class NewsFeed(Base):
    __tablename__ = "news_feeds"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=False, index=True)
    concert_id = Column(UUID(as_uuid=True), ForeignKey("concerts.id", ondelete="CASCADE"), nullable=False, index=True)
    artist_name = Column(String, nullable=False)
    is_read = Column(Boolean, default=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)

    concert = relationship("Concert")
