import secrets

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from config import settings

_bearer = HTTPBearer(auto_error=False)


# 백엔드가 보내는 요청의 `Authorization: Bearer <LLM_EXTRACT_API_KEY>` 검증.
# 백엔드 core/deps.py의 verify_llm_api_key와 동일한 값/패턴을 반대 방향으로 검증한다.
async def verify_backend_api_key(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
) -> None:
    if credentials is None or not secrets.compare_digest(credentials.credentials, settings.LLM_EXTRACT_API_KEY):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="유효하지 않은 API 키입니다.")
