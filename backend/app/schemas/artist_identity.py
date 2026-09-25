from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


class ArtistSummary(BaseModel):
    # 공연 아티스트 표기가 지금 가리키는 canonical(화면 표시용)
    canonical_id: UUID
    mbid: str | None = None
    name: str
    image_url: str | None = None


class IdentityCandidate(BaseModel):
    # 연결 수정 후보 - canonical_id가 있으면 우리 DB에 이미 있는 아티스트, 없으면 MusicBrainz 결과
    canonical_id: UUID | None = None
    mbid: str | None = None
    name: str
    image_url: str | None = None
    country: str | None = None
    type: str | None = None
    disambiguation: str | None = None
    begin_year: str | None = None
    is_current: bool = False


class IdentityCandidatesResponse(BaseModel):
    # no_artist=True면 이 공연에서 "연결할 아티스트 없음"으로 확정된 표기
    artist: str
    current: ArtistSummary | None = None
    no_artist: bool = False
    candidates: list[IdentityCandidate]


class IdentityChangeRequest(BaseModel):
    # canonical_id(우리 DB) / mbid(MusicBrainz 후보) / no_artist 중 하나만
    artist: str
    canonical_id: UUID | None = None
    mbid: str | None = None
    no_artist: bool = False


class IdentityChangeResponse(BaseModel):
    # 바꾼 뒤 이 공연에서의 연결 상태
    artist: str
    current: ArtistSummary | None = None
    no_artist: bool = False


class IdentityChangeRecord(BaseModel):
    # 관리자 페이지 변경 기록 한 건
    id: UUID
    concert_id: UUID
    concert_name: str
    kopis_id: str | None = None
    artist_text: str
    before: ArtistSummary | None = None
    after: ArtistSummary | None = None
    source: str
    changed_by: str | None = None
    created_at: datetime | None = None
    reverted_at: datetime | None = None
