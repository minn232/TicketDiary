from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.database import get_db
from app.core.security import verify_token
from app.models.user import User
from app.services.auth import get_user_by_id

# 인증 관련 의존성 함수들
_bearer = HTTPBearer(auto_error=False)
_optional_bearer = HTTPBearer(auto_error=False)


# 로그인 필수 (카카오 유저 & 게스트 모두 허용)
async def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    db: AsyncSession = Depends(get_db),
) -> User:

    if credentials is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="인증이 필요합니다.")

    # 토큰 검증 (401 Unauthorized)
    user_id = verify_token(credentials.credentials)
    if user_id is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="유효하지 않은 토큰입니다.")

    # 유저 검증 (401 Unauthorized)
    user = await get_user_by_id(db, user_id)
    if user is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="존재하지 않는 유저입니다.")

    return user


# 비로그인 허용
async def get_optional_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(_optional_bearer),
    db: AsyncSession = Depends(get_db),
) -> User | None:
    
    # 토큰이 없는 경우 (비로그인)
    if credentials is None:
        return None

    # 토큰 검증
    user_id = verify_token(credentials.credentials)
    if user_id is None:
        return None

    # 유저 검증
    user = await get_user_by_id(db, user_id)
    if user is None:
        return None

    return user


# LLM팀 API Key 검증 (Bearer {LLM_EXTRACT_API_KEY})
async def verify_llm_api_key(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
) -> None:
    if not settings.LLM_EXTRACT_API_KEY:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="LLM API 키가 설정되지 않았습니다.")
    if credentials is None or credentials.credentials != settings.LLM_EXTRACT_API_KEY:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="유효하지 않은 API 키입니다.")
