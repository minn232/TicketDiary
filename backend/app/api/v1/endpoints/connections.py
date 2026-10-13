from uuid import UUID

from fastapi import APIRouter, Depends, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user, rate_limit_nearby_sighting
from app.models.user import User
from app.schemas.connection import (
    ConnectionCardResponse,
    ConnectionConfirmResponse,
    ConnectionRequestResponse,
    ConnectionResponse,
    NearbyCodeResponse,
    NearbySightingCreate,
    NearbySightingResponse,
)
from app.services import connection as connection_service
from app.services import connection_card as connection_card_service

router = APIRouter()


# 내 폰 맞대기 BLE 광고 코드 (유효하면 기존 코드, 만료가 가까우면 새 코드)
@router.post("/nearby/code", response_model=NearbyCodeResponse)
async def issue_nearby_code(
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await connection_service.get_or_issue_nearby_code(db, current_user.id)


# 맞댐 판정 등록 - 상대 판정도 모이면 연결 요청(pending) 또는 이미 연결(connected)
@router.post("/nearby/sightings", response_model=NearbySightingResponse)
async def report_nearby_sighting(
    body: NearbySightingCreate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
    _rate_limit: None = Depends(rate_limit_nearby_sighting),
):
    return await connection_service.report_sighting(db, current_user.id, body)


# 확인 대기 중인 연결 요청
@router.get("/connections/requests", response_model=list[ConnectionRequestResponse])
async def list_connection_requests(
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await connection_service.list_connection_requests(db, current_user.id)


# 연결 요청 확인 ("OO님 맞나요?" → 예)
@router.post("/connections/requests/{connection_id}/confirm", response_model=ConnectionConfirmResponse)
async def confirm_connection_request(
    connection_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await connection_service.confirm_connection_request(db, current_user.id, connection_id)


# 연결 요청 거절
@router.delete("/connections/requests/{connection_id}", status_code=status.HTTP_204_NO_CONTENT)
async def reject_connection_request(
    connection_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await connection_service.reject_connection_request(db, current_user.id, connection_id)


# 연결 목록
@router.get("/connections", response_model=list[ConnectionResponse])
async def list_connections(
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await connection_service.list_connections(db, current_user.id)


# 연결 끊기
@router.delete("/connections/{peer_user_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_connection(
    peer_user_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await connection_service.delete_connection(db, current_user.id, peer_user_id)


# 연결 카드 (우리 사이 / 함께한 기록 / 다음에 같이)
@router.get("/connections/{peer_user_id}/card", response_model=ConnectionCardResponse)
async def get_connection_card(
    peer_user_id: UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await connection_card_service.get_connection_card(db, current_user.id, peer_user_id)
