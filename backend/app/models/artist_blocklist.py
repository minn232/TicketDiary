import uuid

from sqlalchemy import Column, DateTime, String, func
from sqlalchemy.dialects.postgresql import UUID

from app.core.database import Base


# 아티스트 자리에 반복 오인되는 것으로 확정된 표기 (기존 코드 하드코딩 블록리스트와 별개로,
# 관리자 페이지에서 삭제할 때 즉시 추가되는 DB 백업분 - 배포 없이 바로 반영하기 위함)
class BlockedArtistName(Base):
    __tablename__ = "blocked_artist_names"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name = Column(String, nullable=False, unique=True)
    source = Column(String, nullable=False, default="admin")
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
