import uuid
import enum
from sqlalchemy import Column, String, Enum as SAEnum
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship
from app.core.database import Base


class UserRole(str, enum.Enum):
    KAKAO_USER = "kakao_user"
    GUEST = "guest"


class User(Base):
    __tablename__ = "users"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    kakao_id = Column(String, unique=True, nullable=True, index=True)
    guest_token = Column(String, unique=True, nullable=True, index=True)
    nickname = Column(String, nullable=True)
    profile_image_url = Column(String, nullable=True)
    role = Column(SAEnum(UserRole, values_callable=lambda x: [e.value for e in x]), default=UserRole.KAKAO_USER)

    tickets = relationship("Ticket", backref="user")
    artist_follow = relationship("ArtistFollow", backref="user", uselist=False)
    concert_follow = relationship("ConcertFollow", backref="user", uselist=False)
