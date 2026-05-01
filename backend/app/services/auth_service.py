import hashlib
from uuid import UUID
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from app.models.user import User, UserRole

# 기기 ID를 해싱하여 고유한 게스트 토큰 생성
def _hash_device_id(device_id: str) -> str:
    return hashlib.sha256(device_id.encode()).hexdigest()

# 게스트 로그인
async def guest_login(db: AsyncSession, device_id: str) -> User:
    guest_token = _hash_device_id(device_id)

    # 기존 유저인지 확인
    result = await db.execute(select(User).where(User.guest_token == guest_token))
    user = result.scalar_one_or_none()

    # 기존 유저가 아니라면
    if user is None:
        user = User(guest_token=guest_token, role=UserRole.GUEST)
        db.add(user)
        await db.commit()
        await db.refresh(user)
    return user

# 유저 ID로 유저 조회
async def get_user_by_id(db: AsyncSession, user_id: str | UUID) -> User | None:
    result = await db.execute(select(User).where(User.id == user_id))
    return result.scalar_one_or_none()
