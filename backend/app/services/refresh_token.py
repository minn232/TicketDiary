from datetime import datetime, timedelta, timezone
from uuid import UUID

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.security import generate_refresh_token, hash_refresh_token
from app.models.refresh_token import RefreshToken
from app.models.user import User


# 유저용 리프레시 토큰 신규 발급 (원문은 이번 호출에서만 반환, DB엔 해시만 저장)
async def issue_refresh_token(db: AsyncSession, user_id: UUID, commit: bool = True) -> str:
    token = generate_refresh_token()
    expires_at = datetime.now(timezone.utc) + timedelta(days=settings.REFRESH_TOKEN_EXPIRE_DAYS)

    db.add(RefreshToken(
        user_id=user_id,
        token_hash=hash_refresh_token(token),
        expires_at=expires_at,
    ))
    if commit:
        await db.commit()
    return token


# 리프레시 토큰 검증 후 회전(rotation): 기존 토큰은 즉시 폐기하고 새 access/refresh 토큰 발급용 유저 반환
# 위조/만료/이미 사용(폐기)된 토큰은 401 — 탈취된 토큰의 재사용 시도를 감지하기 위함
async def rotate_refresh_token(db: AsyncSession, token: str) -> tuple[User, str]:
    token_hash = hash_refresh_token(token)
    result = await db.execute(select(RefreshToken).where(RefreshToken.token_hash == token_hash))
    stored = result.scalar_one_or_none()

    if stored is None or stored.revoked or stored.expires_at < datetime.now(timezone.utc):
        raise HTTPException(status_code=401, detail="유효하지 않은 리프레시 토큰입니다.")

    user = await db.get(User, stored.user_id)
    if user is None:
        raise HTTPException(status_code=401, detail="존재하지 않는 유저입니다.")

    stored.revoked = True
    new_token = await issue_refresh_token(db, user.id, commit=False)
    await db.commit()
    return user, new_token


# 로그아웃: 해당 리프레시 토큰 폐기 (이미 없거나 폐기된 토큰이어도 조용히 통과 — 로그아웃은 항상 성공해야 함)
async def revoke_refresh_token(db: AsyncSession, token: str) -> None:
    token_hash = hash_refresh_token(token)
    result = await db.execute(select(RefreshToken).where(RefreshToken.token_hash == token_hash))
    stored = result.scalar_one_or_none()
    if stored is not None and not stored.revoked:
        stored.revoked = True
        await db.commit()
