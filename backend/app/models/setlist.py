import uuid
from sqlalchemy import Column, String, ForeignKey, Text, Boolean
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship
from app.core.database import Base


class RealSetlist(Base):
    __tablename__ = "real_setlists"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    concert_id = Column(UUID(as_uuid=True), ForeignKey("concerts.id"), nullable=False, unique=True)
    setlistfm_id = Column(String, nullable=True)
    songs = Column(Text, nullable=False)
    is_user_edited = Column(Boolean, default=False)
    edited_user_nickname = Column(String, nullable=True)

    concert = relationship("Concert", back_populates="real_setlist")


class PreSetlist(Base):
    __tablename__ = "pre_setlists"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    concert_id = Column(UUID(as_uuid=True), ForeignKey("concerts.id"), nullable=False, unique=True)
    setlistfm_id = Column(String, nullable=True)
    songs = Column(Text, nullable=False)
    is_user_edited = Column(Boolean, default=False)
    edited_user_nickname = Column(String, nullable=True)

    concert = relationship("Concert", back_populates="pre_setlist")
