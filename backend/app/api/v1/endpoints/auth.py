from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession
from app.core.database import get_db
from app.core.security import create_access_token
from app.schemas.auth import GuestLoginRequest, TokenResponse, UserResponse
from app.services.auth_service import guest_login
from app.api.v1.dependencies import get_current_user
from app.models.user import User, UserRole

router = APIRouter()


# 게스트 로그인
@router.post("/guest", response_model=TokenResponse)
async def login_as_guest(body: GuestLoginRequest, db: AsyncSession = Depends(get_db), ):
    user = await guest_login(db, body.device_id)
    token = create_access_token(str(user.id))
    return TokenResponse(access_token=token, user_id=user.id, role=user.role)

# 내 정보 조회
@router.get("/me", response_model=UserResponse)
async def get_me(current_user: User = Depends(get_current_user)):
    return current_user
