import uuid
from sqlalchemy import Column, String, DateTime, Text
from sqlalchemy.dialects.postgresql import UUID, ARRAY, JSONB
from sqlalchemy.orm import relationship
from app.core.database import Base


"""
price JSON 형식: [{"seat_type": "S석", "price": 10000}]
"""
class Concert(Base):
    __tablename__ = "concerts"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    kopis_id = Column(String, nullable=True, index=True)
    name = Column(String, nullable=False)
    artist_name = Column(ARRAY(String), nullable=False)
    venue = Column(String, nullable=True)
    start_date = Column(DateTime(timezone=True), nullable=False)
    end_date = Column(DateTime(timezone=True), nullable=False)
    genre = Column(ARRAY(String), nullable=True)
    poster_url = Column(String, nullable=True)
    description = Column(Text, nullable=True)
    price = Column(JSONB, nullable=True)

    tickets = relationship("Ticket", back_populates="concert")
    timetable = relationship("TimeTable", back_populates="concert", uselist=False)
    real_setlist = relationship("RealSetlist", back_populates="concert", uselist=False)
    pre_setlist = relationship("PreSetlist", back_populates="concert", uselist=False)
