import secrets
import time
from collections import defaultdict
from uuid import UUID

from fastapi import Depends, HTTPException, Request, status
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
    if credentials is None or not secrets.compare_digest(credentials.credentials, settings.LLM_EXTRACT_API_KEY):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="유효하지 않은 API 키입니다.")


# 유저별 요청 시각 기록 (인메모리 sliding window). 서버를 여러 인스턴스로 수평 확장하게 되면
# 인스턴스마다 따로 카운트되어 실효 한도가 늘어나므로, 그땐 Redis 등 공유 저장소로 옮겨야 함.
# 지금은 단일 EC2 인스턴스 배포라 인메모리로 충분
_rate_limit_hits: dict[str, list[float]] = defaultdict(list)


def _check_rate_limit(key: str, max_calls: int, period_seconds: float) -> None:
    now = time.monotonic()
    hits = _rate_limit_hits[key]
    cutoff = now - period_seconds
    while hits and hits[0] < cutoff:
        hits.pop(0)
    if len(hits) >= max_calls:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="요청이 너무 많습니다. 잠시 후 다시 시도해주세요.",
        )
    hits.append(now)


# 게스트 로그인(device_id) 브루트포스 방지: IP당 시간당 20회. 아직 device_id가 프론트에서
# 진짜 난수가 아니라 타임스탬프+객체해시로 생성되고 있어(추후 uuid로 교체 예정) 값 자체의
# 추측 난이도가 낮으므로, 서버 쪽에서라도 무제한 시도를 막아야 함. IP 기준이라 여러 IP로
# 분산하면 우회되지만, 최소한의 완화책 - 근본 해결은 프론트 device_id 생성 방식 교체
async def rate_limit_guest_login(request: Request) -> None:
    client_ip = request.client.host if request.client else "unknown"
    _check_rate_limit(f"guest_login:{client_ip}", max_calls=20, period_seconds=3600)


# 티켓 스캔(Vision OCR, 비용 발생) 남용 방지: 유저당 시간당 30회. 프론트 카메라의 "정렬
# 인식"이 실제 문서 검출이 아니라 밝기/대비/흔들림만 보는 휴리스틱이라 오인식 자동촬영이
# 흔함 - 그런 오탐까지 포함한 순수 어뷰징 방지용 널널한 상한. 실제 티켓 스캔의 빡빡한
# 카운트는 record_meaningful_ticket_scan 참고.
async def rate_limit_ticket_scan(current_user: User = Depends(get_current_user)) -> None:
    _check_rate_limit(f"scan:{current_user.id}", max_calls=30, period_seconds=3600)


_SCAN_COOLDOWN_SECONDS = 2.0


# 카메라 정렬 인식이 포지셔닝 중에도 "정렬됨"으로 오판해서 짧은 시간에 여러 장이 연달아
# 자동 촬영·전송되는 경우가 실측됨(몇 번 테스트에 Vision 요청 200건 이상 소진) - 시간당
# 상한만으론 몇 초 안에 다 소진돼 못 막음. 그래서 직전 스캔과 간격이 너무 짧으면 Vision
# 호출 자체를 생략하고 빈 결과를 반환함(True=쿨다운 중, 매 호출마다 마지막 시각 갱신).
def is_within_scan_cooldown(user_id: UUID) -> bool:
    key = f"scan_cooldown:{user_id}"
    now = time.monotonic()
    hits = _rate_limit_hits[key]
    cutoff = now - _SCAN_COOLDOWN_SECONDS
    while hits and hits[0] < cutoff:
        hits.pop(0)
    was_within_cooldown = len(hits) > 0
    hits.append(now)
    return was_within_cooldown


# OCR 결과가 실제로 티켓 정보를 하나라도 뽑아냈을 때만 호출 - 카메라가 티켓이 아닌
# 사물(책/벽/손 등)을 오인식해서 촬영한 빈 스캔은 이 한도를 깎아먹지 않도록, 진짜
# 스캔 시도에 대해서만 세는 별도의 한도(원래 rate_limit_ticket_scan이 쓰던 값 유지)
def record_meaningful_ticket_scan(user_id: UUID) -> None:
    _check_rate_limit(f"scan_meaningful:{user_id}", max_calls=10, period_seconds=3600)


# 일기 생성(LLM 호출, 비용 발생) 남용 방지: 유저당 시간당 10회
async def rate_limit_diary_generation(current_user: User = Depends(get_current_user)) -> None:
    _check_rate_limit(f"diary:{current_user.id}", max_calls=10, period_seconds=3600)
