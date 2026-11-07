from pydantic import BaseModel, Field, computed_field, field_validator
from uuid import UUID
from app.models.user import UserRole


class TokenResponse(BaseModel):
    # 로그인 성공 시 반환되는 토큰 및 사용자 정보
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    user_id: UUID
    role: UserRole


class GuestLoginRequest(BaseModel):
    # 게스트 로그인 요청 (디바이스 ID로 식별)
    device_id: str


class KakaoLoginRequest(BaseModel):
    # 카카오 로그인 요청 (인증 코드로 로그인)
    code: str


class RefreshTokenRequest(BaseModel):
    # 액세스 토큰 재발급 / 로그아웃 요청 공용 (리프레시 토큰 원문 전달)
    refresh_token: str


class KakaoAuthUrlResponse(BaseModel):
    # 카카오 OAuth 인증 URL 반환
    url: str


class UserProfileUpdate(BaseModel):
    # 회원 프로필 수정 요청 (수정할 필드만 전달)
    nickname: str | None = Field(default=None, max_length=50)
    profile_image_url: str | None = Field(default=None, max_length=2048)

    # 앞뒤 공백 정리 후 빈 닉네임("", "   ")은 거부 - 그대로 저장되면 셋리 수정자/만남 카드에 빈 이름으로 보임
    @field_validator("nickname", mode="after")
    @classmethod
    def _strip_nickname(cls, v: str | None) -> str | None:
        if v is None:
            return v
        v = v.strip()
        if not v:
            raise ValueError("닉네임은 공백일 수 없습니다.")
        return v


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
