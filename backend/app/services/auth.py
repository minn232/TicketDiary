import hashlib
import logging
from uuid import UUID

import httpx
from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.models.user import User, UserRole

logger = logging.getLogger(__name__)

_KAKAO_TOKEN_URL = "https://kauth.kakao.com/oauth/token"
_KAKAO_USER_INFO_URL = "https://kapi.kakao.com/v2/user/me"


# 기기 ID를 해싱하여 고유한 게스트 토큰 생성
def _hash_device_id(device_id: str) -> str:
    return hashlib.sha256(device_id.encode()).hexdigest()


# 게스트 로그인
async def guest_login(db: AsyncSession, device_id: str) -> User:
    guest_token = _hash_device_id(device_id)

    result = await db.execute(select(User).where(User.guest_token == guest_token))
    user = result.scalar_one_or_none()

    if user is not None:
        # 이미 카카오 계정으로 마이그레이션된 경우
        if user.role == UserRole.KAKAO_USER:
            raise HTTPException(status_code=403, detail="이미 카카오 계정으로 연동된 기기입니다.")
        return user

    user = User(guest_token=guest_token, role=UserRole.GUEST)
    db.add(user)
    await db.commit()
    await db.refresh(user)
    return user


# 카카오 인증 코드로 액세스 토큰 교환
async def _exchange_kakao_code(code: str) -> str:
    data = {
        "grant_type": "authorization_code",
        "client_id": settings.KAKAO_REST_API_KEY,
        "redirect_uri": settings.KAKAO_REDIRECT_URI,
        "code": code,
    }
    # 카카오 콘솔에서 Client Secret을 활성화한 경우 필수 (안 보내면 코드와 무관하게
    # invalid_client(KOE010)로 거부됨) - 비활성화 상태면 KAKAO_CLIENT_SECRET이 비어있어 생략됨
    if settings.KAKAO_CLIENT_SECRET:
        data["client_secret"] = settings.KAKAO_CLIENT_SECRET

    async with httpx.AsyncClient() as client:
        response = await client.post(
            _KAKAO_TOKEN_URL,
            data=data,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
    if response.status_code != 200:
        logger.warning(f"카카오 토큰 교환 실패: {response.status_code} {response.text}")
        raise HTTPException(status_code=400, detail="유효하지 않은 카카오 인증 코드입니다.")
    return response.json()["access_token"]


# 카카오 액세스 토큰으로 사용자 정보 조회
async def _get_kakao_user_info(access_token: str) -> dict:
    async with httpx.AsyncClient() as client:
        response = await client.get(
            _KAKAO_USER_INFO_URL,
            headers={"Authorization": f"Bearer {access_token}"},
        )
    if response.status_code != 200:
        raise HTTPException(status_code=400, detail="카카오 사용자 정보를 가져오는 데 실패했습니다.")
    return response.json()


# 카카오 로그인
async def kakao_login(db: AsyncSession, code: str) -> User:
    access_token = await _exchange_kakao_code(code)
    user_info = await _get_kakao_user_info(access_token)

    kakao_id = str(user_info["id"])
    profile = user_info.get("kakao_account", {}).get("profile", {})
    nickname = profile.get("nickname")
    profile_image_url = profile.get("thumbnail_image_url")

    # 기존 유저인지 확인
    result = await db.execute(select(User).where(User.kakao_id == kakao_id))
    user = result.scalar_one_or_none()

    # 기존 유저가 아니라면 생성, 맞다면 프로필 갱신
    if user is None:
        user = User(
            kakao_id=kakao_id,
            nickname=nickname,
            profile_image_url=profile_image_url,
            role=UserRole.KAKAO_USER,
        )
        db.add(user)
    else:
        user.nickname = nickname
        user.profile_image_url = profile_image_url

    await db.commit()
    await db.refresh(user)
    return user


# 게스트 계정 카카오 계정 연동
async def migrate_to_kakao(db: AsyncSession, current_user: User, code: str) -> User:
    access_token = await _exchange_kakao_code(code)
    user_info = await _get_kakao_user_info(access_token)

    kakao_id = str(user_info["id"])

    # 동일한 카카오 계정이 이미 가입된 경우
    result = await db.execute(select(User).where(User.kakao_id == kakao_id))
    if result.scalar_one_or_none():
        raise HTTPException(status_code=409, detail="이미 가입된 카카오 계정입니다.")

    # 카카오 계정으로 업데이트
    profile = user_info.get("kakao_account", {}).get("profile", {})
    current_user.kakao_id = kakao_id
    current_user.nickname = profile.get("nickname")
    current_user.profile_image_url = profile.get("thumbnail_image_url")
    current_user.role = UserRole.KAKAO_USER

    await db.commit()
    await db.refresh(current_user)
    return current_user


# 유저 ID로 유저 조회
async def get_user_by_id(db: AsyncSession, user_id: str | UUID) -> User | None:
    result = await db.execute(select(User).where(User.id == user_id))
    return result.scalar_one_or_none()
