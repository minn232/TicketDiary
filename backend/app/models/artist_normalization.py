import uuid
from datetime import datetime, timezone

from sqlalchemy import Boolean, Column, DateTime, ForeignKey, Integer, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship

from app.core.database import Base


# MusicBrainz로 확인된(또는 유저가 직접 확정한) 아티스트 1명 = canonical row 1개.
# mbid가 NULL이면 유저 입력으로만 생성된 canonical(MusicBrainz에 없는 아티스트)이라는 뜻.
class CanonicalArtist(Base):
    __tablename__ = "canonical_artists"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    mbid = Column(String, nullable=True, unique=True, index=True)
    canonical_name = Column(String, nullable=False)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    aliases = relationship("ArtistAlias", back_populates="canonical_artist", cascade="all, delete-orphan")


# canonical 아티스트 1명에 대해 실제로 관측된 표기 변형들(원문 그대로 보존, alias_text는
# 조회용으로 별도 정규화해서 비교함 - artist_normalization.py의 _normalize_alias_text 참고).
# 이후 같은 표기가 다시 추출되면 API 호출 없이 이 테이블만 조회해서 canonical을 즉시 재사용.
class ArtistAlias(Base):
    __tablename__ = "artist_aliases"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    canonical_artist_id = Column(UUID(as_uuid=True), ForeignKey("canonical_artists.id"), nullable=False)
    alias_text = Column(String, nullable=False, index=True)
    # "musicbrainz"(API 조회로 확인) | "user_input"(유저가 미확정 아티스트를 직접 채움)
    source = Column(String, nullable=False)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    canonical_artist = relationship("CanonicalArtist", back_populates="aliases")


# 콘서트에 저장된 아티스트 표기 하나하나의 정규화 진행 상태. 웹훅은 이 테이블에 pending으로만
# 큐잉하고(외부 호출 없음), 별도 배치(app/services/artist_normalization.py)가 이 큐를 소비해서
# MusicBrainz 조회 + Concert.artist_name/ConcertLineup.artist 표기 치환까지 수행한다.
#
# status: "pending"(아직 조회 안 함/실패해서 재시도 대기) | "matched"(canonical로 확정)
#         | "unconfirmed"(MusicBrainz에 없음, 원본 표기 그대로 유지) | "ambiguous"(후보 다수, 확정 못 함)
class ArtistNormalizationStatus(Base):
    __tablename__ = "artist_normalization_status"

    # 같은 (공연, 표기) 조합을 웹훅이 여러 번 큐잉해도(재크롤/재추출 등) 중복 row가 쌓이지
    # 않게 함 - 큐잉 쪽(queue_for_normalization)이 이 제약을 보고 upsert 대신 "이미 있으면 스킵"으로 구현됨
    __table_args__ = (
        UniqueConstraint("concert_id", "artist_text", name="uq_artist_normalization_status_concert_artist"),
    )

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    concert_id = Column(UUID(as_uuid=True), ForeignKey("concerts.id"), nullable=False)
    # 웹훅이 큐잉할 당시 Concert.artist_name에 실제로 저장돼 있던 원문 표기. 배치가 이 문자열을
    # 키로 삼아 Concert.artist_name/ConcertLineup.artist에서 찾아 canonical로 치환한다.
    artist_text = Column(String, nullable=False)
    status = Column(String, nullable=False, default="pending", index=True)
    attempt_count = Column(Integer, nullable=False, default=0)
    last_attempted_at = Column(DateTime(timezone=True), nullable=True)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))


# 사람(멤버) canonical과 그룹(밴드) canonical 사이의 소속 관계 - alias로 합치지 않고 별도
# 엣지로 저장(멤버가 솔로 활동을 할 수도 있어서 "같은 아티스트"로 취급하면 안 됨). MusicBrainz의
# "member of band" 관계에서 채워지며, 새로 매치된 canonical 1건당 딱 1단계(그 아티스트 본인의
# 관계)만 조회 - 연쇄적으로 상대방의 상대방까지 훑지는 않음(API 호출량 방지, artist_normalization.py 참고).
# is_current=False(탈퇴 멤버)는 저장은 해두지만 뉴스피드 매칭(kopis.py)에서는 제외한다 -
# 탈퇴한 멤버의 팔로워에게 그 밴드의 신곡 공연까지 뜨는 건 원치 않는다는 결정.
class ArtistGroupMembership(Base):
    __tablename__ = "artist_group_memberships"

    __table_args__ = (
        UniqueConstraint("member_canonical_id", "group_canonical_id", name="uq_artist_group_membership"),
    )

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    member_canonical_id = Column(UUID(as_uuid=True), ForeignKey("canonical_artists.id"), nullable=False)
    group_canonical_id = Column(UUID(as_uuid=True), ForeignKey("canonical_artists.id"), nullable=False)
    is_current = Column(Boolean, nullable=False, default=True)
    source = Column(String, nullable=False, default="musicbrainz")
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
