from pydantic import BaseModel
from uuid import UUID
from app.models.user import UserRole


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user_id: UUID
    role: UserRole


class GuestLoginRequest(BaseModel):
    device_id: str


class UserResponse(BaseModel):
    model_config = {"from_attributes": True}

    id: UUID
    nickname: str | None
    profile_image_url: str | None
    role: UserRole
