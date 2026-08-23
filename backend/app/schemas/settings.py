import json

from pydantic import BaseModel, field_validator


class NotificationSettings(BaseModel):
    # 알림 설정 항목
    delivery: bool = True
    day_before: bool = True
    concert_day: bool = True
    ticketing: bool = True
    new_concert: bool = True


class NotificationSettingsUpdate(BaseModel):
    # 알림 설정 부분 수정 요청 (보낸 필드만 반영, 나머지는 기존값 유지)
    delivery: bool | None = None
    day_before: bool | None = None
    concert_day: bool | None = None
    ticketing: bool | None = None
    new_concert: bool | None = None


class UserSettingsResponse(BaseModel):
    model_config = {"from_attributes": True}

    # 유저 설정 조회 응답
    fcm_token: str | None
    show_predicted_setlist: bool
    notification_settings: NotificationSettings

    # users.notification_settings 컬럼이 NOT NULL이라(마이그레이션 d4e5f6a7b8c9로 확정) v가
    # None으로 올 일은 이제 없음 - 컬럼 추가 초기(마이그레이션 전) 방어코드였던 None 분기는 제거함.
    # v가 문자열로 오는 경우만 남겨서 json.loads로 파싱.
    @field_validator("notification_settings", mode="before")
    @classmethod
    def _parse_notification_settings(cls, v):
        if isinstance(v, str):
            return json.loads(v)
        return v


class FcmTokenUpdate(BaseModel):
    # FCM 토큰 업데이트 요청
    fcm_token: str


class UserSettingsUpdate(BaseModel):
    # 유저 설정 수정 요청
    show_predicted_setlist: bool | None = None
    notification_settings: NotificationSettingsUpdate | None = None
