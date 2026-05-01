from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.ext.asyncio import AsyncSession
from app.core.database import get_db
from app.core.security import verify_token
from app.models.user import User
from app.services.auth_service import get_user_by_id

# HTTPBearer는 요청의 Authorization: Bearer <token> 헤더를 자동으로 파싱해준다.
# auto_error=True(기본값)이므로 헤더가 없으면 FastAPI가 자동으로 403을 반환한다.
bearer_scheme = HTTPBearer()

# 현재 인증된 유저 반환
async def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(bearer_scheme),
    db: AsyncSession = Depends(get_db),
) -> User:
    # 토큰 검증
    user_id = verify_token(credentials.credentials)
    if user_id is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token")
    
    # DB에서 유저 조회
    user = await get_user_by_id(db, user_id)
    if user is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="User not found")
    
    return user
