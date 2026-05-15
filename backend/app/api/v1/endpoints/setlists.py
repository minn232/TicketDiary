from uuid import UUID
from pydantic import BaseModel
from fastapi import APIRouter, Depends, status
from sqlalchemy.ext.asyncio import AsyncSession
from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.user import User
from app.schemas.setlist import (
    RealSetlistResponse, PreSetlistResponse, SetlistFmCandidate, SetlistEditRequest,
)
from app.services.setlist import (
    get_real_setlist,
    search_setlists_for_concert,
    fetch_and_save_real_setlist,
    update_real_setlist,
)
from app.services.pre_setlist import get_pre_setlist, generate_pre_setlist, update_pre_setlist

router = APIRouter()


class FetchSetlistRequest(BaseModel):
    # Setlist.fm ID로 셋리스트 가져오기 요청
    setlistfm_id: str


# 저장된 실제 셋리스트 조회
@router.get("/{concert_id}/setlist", response_model=RealSetlistResponse)
async def get_real_setlist_endpoint(
    concert_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await get_real_setlist(db, concert_id)


# concert 아티스트, 공연일 기반 Setlist.fm 후보 검색
@router.get("/{concert_id}/setlist/search", response_model=list[SetlistFmCandidate])
async def search_real_setlists(
    concert_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await search_setlists_for_concert(db, concert_id)


# Setlist.fm ID로 셋리스트 가져와 저장
@router.post("/{concert_id}/setlist", response_model=RealSetlistResponse, status_code=status.HTTP_201_CREATED)
async def fetch_real_setlist(
    concert_id: UUID,
    body: FetchSetlistRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await fetch_and_save_real_setlist(db, concert_id, body.setlistfm_id)


# 실제 셋리스트 유저 수정
@router.patch("/{concert_id}/setlist", response_model=RealSetlistResponse)
async def edit_real_setlist(
    concert_id: UUID,
    body: SetlistEditRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await update_real_setlist(db, concert_id, body.songs, current_user.nickname)


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
