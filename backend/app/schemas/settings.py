import json

from pydantic import BaseModel, field_validator


class NotificationSettings(BaseModel):
    # 알림 설정 항목
    delivery: bool = True
    before_concert: bool = True
    ticketing: bool = True
    new_concert: bool = True


class UserSettingsResponse(BaseModel):
    model_config = {"from_attributes": True}

    # 유저 설정 조회 응답
    fcm_token: str | None
    show_predicted_setlist: bool
    notification_settings: NotificationSettings

    @field_validator("notification_settings", mode="before")
    @classmethod
    def _parse_notification_settings(cls, v):
        if v is None:
            return {"delivery": True, "before_concert": True, "ticketing": True, "new_concert": True}
        if isinstance(v, str):
            return json.loads(v)
        return v


class FcmTokenUpdate(BaseModel):
    # FCM 토큰 업데이트 요청
    fcm_token: str


class UserSettingsUpdate(BaseModel):
    # 유저 설정 수정 요청
    show_predicted_setlist: bool | None = None
    notification_settings: NotificationSettings | None = None
