import uuid
import enum

from sqlalchemy import Column, String, Boolean, Enum as SAEnum, text
from sqlalchemy.dialects.postgresql import UUID, JSONB
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
    fcm_token = Column(String, nullable=True)
    show_predicted_setlist = Column(Boolean, nullable=False, server_default=text("true"))
    notification_settings = Column(
        JSONB,
        nullable=False,
        server_default=text(
            '\'{"delivery": true, "day_before": true, "concert_day": true, '
            '"ticketing": true, "new_concert": true}\'::jsonb'
        ),
        default=lambda: {
            "delivery": True,
            "day_before": True,
            "concert_day": True,
            "ticketing": True,
            "new_concert": True,
        },
    )
    tickets = relationship("Ticket", backref="user", cascade="all, delete-orphan")
    artist_follow = relationship("ArtistFollow", backref="user", uselist=False, cascade="all, delete")
    concert_follow = relationship("ConcertFollow", backref="user", uselist=False, cascade="all, delete")
    news_feeds = relationship("NewsFeed", cascade="all, delete-orphan")
