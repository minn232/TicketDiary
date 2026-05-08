from pydantic import BaseModel, computed_field
from uuid import UUID
from app.models.user import UserRole


class TokenResponse(BaseModel):
    # 로그인 성공 시 반환되는 토큰 및 사용자 정보
    access_token: str
    token_type: str = "bearer"
    user_id: UUID
    role: UserRole


class GuestLoginRequest(BaseModel):
    # 게스트 로그인 요청 (디바이스 ID로 식별)
    device_id: str


class KakaoLoginRequest(BaseModel):
    # 카카오 로그인 요청 (인증 코드로 로그인)
    code: str


class KakaoAuthUrlResponse(BaseModel):
    # 카카오 OAuth 인증 URL 반환
    url: str


class UserResponse(BaseModel):
    # 사용자 정보 응답
    model_config = {"from_attributes": True}

    id: UUID
    nickname: str | None
    profile_image_url: str | None
    role: UserRole

    # is_guest 필드 role 계산
    @computed_field
    @property
    def is_guest(self) -> bool:
        return self.role == UserRole.GUEST
