from datetime import date
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status
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


# show_predicted_setlist 설정 체크 (비활성화 시 403)
def _check_pre_setlist_enabled(user: User) -> None:
    if not user.show_predicted_setlist:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="예상 셋리스트 표시가 비활성화되어 있습니다.")


# 저장된 예상 셋리스트 조회
@router.get("/{concert_id}/setlist/pre", response_model=PreSetlistResponse)
async def get_pre_setlist_endpoint(
    concert_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    _check_pre_setlist_enabled(current_user)
    return await get_pre_setlist(db, concert_id)


# 아티스트 과거 공연 기반 예상 셋리스트 생성
@router.post("/{concert_id}/setlist/pre/generate", response_model=PreSetlistResponse, status_code=status.HTTP_201_CREATED)
async def generate_pre_setlist_endpoint(
    concert_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    _check_pre_setlist_enabled(current_user)
    return await generate_pre_setlist(db, concert_id)


# 예상 셋리스트 유저 수정
@router.patch("/{concert_id}/setlist/pre", response_model=PreSetlistResponse)
async def edit_pre_setlist(
    concert_id: UUID,
    body: SetlistEditRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    _check_pre_setlist_enabled(current_user)
    return await update_pre_setlist(db, concert_id, body.songs, current_user.nickname)
