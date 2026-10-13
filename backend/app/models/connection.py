import uuid

from sqlalchemy import Column, DateTime, ForeignKey, Index, Integer, String, UniqueConstraint, func
from sqlalchemy.dialects.postgresql import UUID

from app.core.database import Base


# 폰 맞대기용 BLE 광고 코드 - 광고에 user_id 대신 이 4바이트 코드를 실음(유효기간마다 바뀌어 추적이 어려움).
# 오프라인 판정을 나중에 올려도 풀 수 있게 만료된 코드도 남겨두고, 판정 시각 기준으로 찾음
class NearbyCode(Base):
    __tablename__ = "nearby_codes"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    code = Column(String, nullable=False, index=True)
    valid_from = Column(DateTime(timezone=True), nullable=False)
    valid_until = Column(DateTime(timezone=True), nullable=False)
    # 이 코드로 맞대기 화면을 마지막으로 연 시각 - 이번 시도 판정만 짝짓는 기준
    session_started_at = Column(DateTime(timezone=True), nullable=True)


# 맞댐 판정 기록 - 각 폰이 "이 코드를 맞댐 수준으로 봤다"고 올린 것.
# 양쪽이 서로를 본 기록이 짧은 시간 안에 모이면 연결 요청을 만듦
class NearbySighting(Base):
    __tablename__ = "nearby_sightings"
    # 상대가 나를 본 기록을 찾는 조회(observer=상대, observed=나)용
    __table_args__ = (Index("ix_nearby_sightings_pair", "observer_user_id", "observed_user_id"),)

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    observer_user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    observed_user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    # 판정 당시 1초 평균 RSSI - 기준값 조정용 기록
    rssi = Column(Integer, nullable=True)
    seen_at = Column(DateTime(timezone=True), nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)


# 유저 간 연결 (쌍당 1행) - user_a_id < user_b_id로 정렬해 저장해 (A,B)/(B,A) 중복을 막음.
# connected_at이 비어 있으면 양쪽 확인을 기다리는 요청 상태
class UserConnection(Base):
    __tablename__ = "user_connections"
    __table_args__ = (UniqueConstraint("user_a_id", "user_b_id", name="uq_user_connection"),)

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_a_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    # 유니크 제약은 user_a_id가 앞이라 b 쪽으로 내 연결을 찾는 조회엔 별도 인덱스 필요
    user_b_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    a_confirmed_at = Column(DateTime(timezone=True), nullable=True)
    b_confirmed_at = Column(DateTime(timezone=True), nullable=True)
    requested_at = Column(DateTime(timezone=True), nullable=False)
    connected_at = Column(DateTime(timezone=True), nullable=True)
    # 연결 후에도 다시 맞대면 갱신 - 연결 목록 정렬용
    last_met_at = Column(DateTime(timezone=True), nullable=True)
