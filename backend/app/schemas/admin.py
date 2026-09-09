from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


class AdminConcertListItem(BaseModel):
    model_config = {"from_attributes": True}

    # 관리자 목록 한 줄 - flagged_count는 unconfirmed/ambiguous 상태인 아티스트 수(0이면 정상).
    # llm_exclusion_reasons가 비어있지 않으면 send_posters_for_artist_extraction 대상이 아니라는
    # 뜻(포스터 LLM 추출이 영영 안 옴) - 크롤링 등 다른 경로로만 채워질 수 있으니 우선 확인 대상.
    # admin_reviewed_at은 NULL이면 미검수
    id: UUID
    kopis_id: str | None
    name: str
    artist_name: list[str]
    poster_url: str | None
    start_date: datetime
    flagged_count: int
    llm_exclusion_reasons: list[str]
    admin_reviewed_at: datetime | None


class AdminConcertListResponse(BaseModel):
    # 페이지네이션 포함 목록 응답
    items: list[AdminConcertListItem]
    total: int
    page: int
    page_size: int


class AdminArtistStatus(BaseModel):
    # 아티스트 표기 하나의 정규화 상태 (concert 상세 화면에서 뱃지로 보여주기 위함)
    artist_text: str
    status: str
    attempt_count: int


class AdminConcertDetail(BaseModel):
    model_config = {"from_attributes": True}

    # 상세 화면 - 포스터 원본과 대조하며 검수/수정하기 위한 필드 구성.
    # group_memberships: artist_name 중 밴드로 알려진 이름 -> 그 밴드의 현재 멤버명 목록
    id: UUID
    kopis_id: str | None
    name: str
    artist_name: list[str]
    poster_url: str | None
    venue: str | None
    start_date: datetime
    event_type: str
    ticketing_links: dict[str, str] | None
    statuses: list[AdminArtistStatus]
    group_memberships: dict[str, list[str]]
    admin_reviewed_at: datetime | None


class AdminArtistRenameRequest(BaseModel):
    # confirm_artist_name_change에 그대로 넘기는 페이로드(G안과 동일 로직)
    original_name: str
    confirmed_name: str


class AdminArtistAddRequest(BaseModel):
    # add_artist_name에 그대로 넘기는 페이로드 - LLM/KOPIS 둘 다 놓친 아티스트 수기 추가용
    name: str


class AdminGroupMembershipRequest(BaseModel):
    # set_group_membership에 그대로 넘기는 페이로드 - 밴드명+멤버 여러 명이 개별 표기로 따로
    # 뽑힌 걸 밴드명 하나로 접고 멤버 관계를 등록하기 위함
    group_name: str
    member_names: list[str]


class AdminNameOption(BaseModel):
    # 표시명 후보 하나 - source: canonical(MusicBrainz 원문) / musicbrainz / wikidata / user_input / admin
    text: str
    source: str


class AdminArtistAlias(BaseModel):
    # 아티스트 상세 화면의 별칭 한 줄 - id를 같이 내려줘야 프론트가 텍스트 재검색 없이 바로
    # 삭제(remove_artist_alias) API를 호출할 수 있음
    id: UUID
    text: str
    source: str


class AdminCanonicalNameOptions(BaseModel):
    # 표시명 선택 UI(admin.html)가 그대로 렌더링하는 응답 - current가 지금 화면에 뜨는 값
    canonical_id: UUID
    canonical_name: str
    display_name: str | None
    current: str
    mbid: str | None
    options: list[AdminNameOption]


class AdminDisplayNameRequest(BaseModel):
    # 표시명 수동 지정 요청 페이로드
    display_name: str


class AdminArtistListItem(BaseModel):
    model_config = {"from_attributes": True}

    # 아티스트 목록 한 줄 - is_group/member_of_count로 그룹/멤버 관계 유무를 한눈에 구분.
    # is_unused=True면 이 아티스트명(+별칭)이 어느 공연에도 안 나옴 - 삭제 후보 표시용
    id: UUID
    canonical_name: str
    display_name: str | None
    mbid: str | None
    alias_count: int
    is_group: bool
    member_of_count: int
    is_unused: bool


class AdminArtistListResponse(BaseModel):
    # 아티스트 목록 페이지 응답
    items: list[AdminArtistListItem]
    total: int
    page: int
    page_size: int


class AdminArtistConcertItem(BaseModel):
    # 아티스트 상세 화면의 "출연 공연" 한 줄
    id: UUID
    name: str
    poster_url: str | None
    start_date: datetime


class AdminArtistRef(BaseModel):
    # group_members/member_of 한 줄 - id를 같이 내려줘야 프론트가 이름 재검색 없이 바로
    # 삭제(add_group_relation/remove_group_relation) API를 호출할 수 있음
    id: UUID
    name: str


class AdminArtistDetail(BaseModel):
    model_config = {"from_attributes": True}

    # 아티스트 상세 - concerts는 이 아티스트 자신의 표기로 나온 공연, group_concerts는 이
    # 아티스트가 멤버로 속한 그룹 이름으로 나온 공연(member_of가 있을 때만 채워짐)
    id: UUID
    canonical_name: str
    display_name: str | None
    mbid: str | None
    profile_image_url: str | None
    aliases: list[AdminArtistAlias]
    group_members: list[AdminArtistRef]
    member_of: list[AdminArtistRef]
    concerts: list[AdminArtistConcertItem]
    group_concerts: list[AdminArtistConcertItem]


class AdminAddAliasRequest(BaseModel):
    # add_artist_alias에 그대로 넘기는 페이로드
    alias_text: str


class AdminGroupRelationAddRequest(BaseModel):
    # add_group_relation에 그대로 넘기는 페이로드. role="member": other_name을 이 아티스트의
    # 멤버로 등록. role="group": other_name을 이 아티스트가 속한 그룹으로 등록
    other_name: str
    role: str
