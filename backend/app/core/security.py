import hashlib
import secrets
from datetime import datetime, timedelta, timezone

from jose import jwt, JWTError

from app.core.config import settings


# 액세스 토큰 생성
def create_access_token(subject: str) -> str:
    expire = datetime.now(timezone.utc) + timedelta(minutes=settings.ACCESS_TOKEN_EXPIRE_MINUTES)
    return jwt.encode(
        {"sub": subject, "exp": expire},
        settings.SECRET_KEY,
        algorithm=settings.ALGORITHM,
    )


# 토큰 검증 및 사용자 식별
def verify_token(token: str) -> str | None:
    try:
        payload = jwt.decode(token, settings.SECRET_KEY, algorithms=[settings.ALGORITHM])
        return payload.get("sub")
    except JWTError:
        return None


# 리프레시 토큰 원문 생성 (JWT 아닌 불투명 랜덤 문자열 — DB 조회로만 검증되므로 자체 서명 불필요)
def generate_refresh_token() -> str:
    return secrets.token_urlsafe(48)


# 리프레시 토큰 원문 -> DB 저장용 해시 (원문은 클라이언트만 보관, 서버는 해시만 저장)
def hash_refresh_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()
