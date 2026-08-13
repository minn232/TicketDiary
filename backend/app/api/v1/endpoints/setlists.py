from datetime import date
from uuid import UUID

from fastapi import APIRouter, Depends, Query, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.user import User
from app.schemas.setlist import (
    RealSetlistResponse, PreSetlistResponse, SetlistFmCandidate,
    SetlistEditRequest, FetchSetlistRequest,
)
from app.services.setlist import (
    get_real_setlist,
    search_setlists_for_concert,
    fetch_and_save_real_setlist,
    generate_real_setlist_auto,
    update_real_setlist,
)
from app.services.pre_setlist import get_pre_setlist, generate_pre_setlist, update_pre_setlist

router = APIRouter()


# 저장된 실제 셋리스트 조회. 여러 날짜에 걸친 공연이면 date 쿼리파라미터 필수
# (하루짜리 공연은 생략 가능 - 자동으로 그 날짜로 결정됨)
@router.get("/{concert_id}/setlist", response_model=RealSetlistResponse)
async def get_real_setlist_endpoint(
    concert_id: UUID,
    performance_date: date | None = Query(None, alias="date"),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await get_real_setlist(db, concert_id, performance_date)


# concert 아티스트, 공연일 기반 Setlist.fm 후보 검색
@router.get("/{concert_id}/setlist/search", response_model=list[SetlistFmCandidate])
async def search_real_setlists(
    concert_id: UUID,
    performance_date: date | None = Query(None, alias="date"),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await search_setlists_for_concert(db, concert_id, performance_date)


# Setlist.fm ID로 셋리스트 가져와 저장
@router.post("/{concert_id}/setlist", response_model=RealSetlistResponse, status_code=status.HTTP_201_CREATED)
async def fetch_real_setlist(
    concert_id: UUID,
    body: FetchSetlistRequest,
    performance_date: date | None = Query(None, alias="date"),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await fetch_and_save_real_setlist(db, concert_id, body.setlistfm_id, performance_date)


# 실제 셋리스트 유저 수정
@router.patch("/{concert_id}/setlist", response_model=RealSetlistResponse)
async def edit_real_setlist(
    concert_id: UUID,
    body: SetlistEditRequest,
    performance_date: date | None = Query(None, alias="date"),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await update_real_setlist(db, concert_id, body.songs, current_user.nickname, performance_date)


# 아티스트별 자동 검색+병합으로 실제 셋리스트 생성(페스티벌뿐 아니라 단독 공연도 동작 -
# generate_real_setlist_auto 참고). 매일 자동으로 도는 백필 잡(retry_real_setlist_generation)이
# 주로 쓰지만, 유저가 수동으로 "다시 찾기"를 트리거할 수 있게 엔드포인트도 남겨둠. 티켓 기준
# twin은 tickets.py의 generate_ticket_real_setlist_auto 참고.
@router.post(
    "/{concert_id}/setlist/generate-festival",
    response_model=RealSetlistResponse,
    status_code=status.HTTP_201_CREATED,
)
async def generate_real_setlist_auto_endpoint(
    concert_id: UUID,
    performance_date: date | None = Query(None, alias="date"),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await generate_real_setlist_auto(db, concert_id, performance_date)


# show_predicted_setlist는 이제 "조회 자체를 막는 스위치"가 아니라, 프론트에서
# 블러 처리 여부만 결정하는 화면 취향 값으로 재정의됨(꺼도 데이터는 그대로
# 내려줘야 프론트가 롱탭/홀드로 블러를 잠깐 풀어 보여주는 기능을 만들 수 있음).
# 그래서 여기서 하던 403 게이팅은 제거함 — 값 자체(GET/PATCH /settings)는
# 그대로 유지.


# 저장된 예상 셋리스트 조회
@router.get("/{concert_id}/setlist/pre", response_model=PreSetlistResponse)
async def get_pre_setlist_endpoint(
    concert_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await get_pre_setlist(db, concert_id)


# 아티스트 과거 공연 기반 예상 셋리스트 생성
@router.post("/{concert_id}/setlist/pre/generate", response_model=PreSetlistResponse, status_code=status.HTTP_201_CREATED)
async def generate_pre_setlist_endpoint(
    concert_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await generate_pre_setlist(db, concert_id)


# 예상 셋리스트 유저 수정
@router.patch("/{concert_id}/setlist/pre", response_model=PreSetlistResponse)
async def edit_pre_setlist(
    concert_id: UUID,
    body: SetlistEditRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await update_pre_setlist(db, concert_id, body.songs, current_user.nickname)
