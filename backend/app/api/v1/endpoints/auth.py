import urllib.parse

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.security import create_access_token
from app.core.config import settings
from app.core.deps import get_current_user, rate_limit_guest_login
from app.schemas.auth import (
    GuestLoginRequest,
    KakaoLoginRequest,
    KakaoAuthUrlResponse,
    RefreshTokenRequest,
    TokenResponse,
    UserProfileUpdate,
    UserResponse,
)
from app.services.auth import guest_login, kakao_login, migrate_to_kakao, update_profile
from app.services.refresh_token import issue_refresh_token, revoke_refresh_token, rotate_refresh_token
from app.models.user import User, UserRole

router = APIRouter()


# 게스트 로그인
@router.post("/guest", response_model=TokenResponse)
async def login_as_guest(
    body: GuestLoginRequest,
    db: AsyncSession = Depends(get_db),
    _rate_limit: None = Depends(rate_limit_guest_login),
):
    user = await guest_login(db, body.device_id)
    token = create_access_token(str(user.id))
    refresh_token = await issue_refresh_token(db, user.id)
    return TokenResponse(access_token=token, refresh_token=refresh_token, user_id=user.id, role=user.role)


# 카카오 OAuth 인증 URL 조회
@router.get("/kakao/url", response_model=KakaoAuthUrlResponse)
async def get_kakao_auth_url():
    params = {
        "client_id": settings.KAKAO_REST_API_KEY,
        "redirect_uri": settings.KAKAO_REDIRECT_URI,
        "response_type": "code",
    }
    url = "https://kauth.kakao.com/oauth/authorize?" + urllib.parse.urlencode(params)
    return KakaoAuthUrlResponse(url=url)


# 카카오 로그인
@router.post("/kakao", response_model=TokenResponse)
async def login_with_kakao(body: KakaoLoginRequest, db: AsyncSession = Depends(get_db)):
    user = await kakao_login(db, body.code)
    token = create_access_token(str(user.id))
    refresh_token = await issue_refresh_token(db, user.id)
    return TokenResponse(access_token=token, refresh_token=refresh_token, user_id=user.id, role=user.role)


# 게스트 -> 카카오 계정 연동 (마이그레이션)
@router.post("/migrate", response_model=TokenResponse)
async def migrate_guest_to_kakao(
    body: KakaoLoginRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    if current_user.role != UserRole.GUEST:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="게스트 유저만 마이그레이션할 수 있습니다.")

    user = await migrate_to_kakao(db, current_user, body.code)
    token = create_access_token(str(user.id))
    refresh_token = await issue_refresh_token(db, user.id)
    return TokenResponse(access_token=token, refresh_token=refresh_token, user_id=user.id, role=user.role)


# 액세스 토큰 재발급 (리프레시 토큰 회전 — 기존 리프레시 토큰은 이 호출로 폐기되고 새 리프레시 토큰이 발급됨)
@router.post("/refresh", response_model=TokenResponse)
async def refresh_access_token(body: RefreshTokenRequest, db: AsyncSession = Depends(get_db)):
    user, new_refresh_token = await rotate_refresh_token(db, body.refresh_token)
    token = create_access_token(str(user.id))
    return TokenResponse(access_token=token, refresh_token=new_refresh_token, user_id=user.id, role=user.role)


# 로그아웃 (해당 리프레시 토큰 폐기 — 액세스 토큰은 자체 만료될 때까지 유효하나 재발급은 불가능해짐)
@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(body: RefreshTokenRequest, db: AsyncSession = Depends(get_db)):
    await revoke_refresh_token(db, body.refresh_token)


# 내 정보 조회
@router.get("/me", response_model=UserResponse)
async def get_me(current_user: User = Depends(get_current_user)):
    return current_user


# 회원 프로필 수정 (닉네임/프로필 이미지)
@router.patch("/me", response_model=UserResponse)
async def update_me(
    body: UserProfileUpdate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await update_profile(db, current_user, body.nickname, body.profile_image_url)


# 회원 탈퇴 (데이터 삭제)
@router.delete("/me", status_code=status.HTTP_204_NO_CONTENT)
async def delete_me(
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await db.delete(current_user)
    await db.commit()
