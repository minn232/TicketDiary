from pathlib import Path
from pydantic_settings import BaseSettings, SettingsConfigDict

_ENV_FILE = Path(__file__).resolve().parent.parent.parent / ".env"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=str(_ENV_FILE), env_file_encoding='utf-8-sig', extra="ignore")

    DATABASE_URL: str = "postgresql+asyncpg://postgres:password@localhost:5432/ticketdiary"
    SYNC_DATABASE_URL: str = "postgresql://postgres:password@localhost:5432/ticketdiary"
    SECRET_KEY: str
    ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 1440
    KAKAO_REST_API_KEY: str = ""
    KAKAO_REDIRECT_URI: str = ""
    KOPIS_API_KEY: str = ""
    KOPIS_BASE_URL: str = "http://www.kopis.or.kr/openApi/restful"
    SETLISTFM_API_KEY: str = ""
    SETLISTFM_BASE_URL: str = "https://api.setlist.fm/rest/1.0"
    OPENAI_API_KEY: str = ""
    OPENAI_MODEL: str = "gpt-4o-mini"
    GOOGLE_VISION_API_KEY: str = ""
    LLM_EXTRACT_URL: str = ""
    LLM_EXTRACT_API_KEY: str = ""
    AWS_ACCESS_KEY_ID: str = ""
    AWS_SECRET_ACCESS_KEY: str = ""
    AWS_REGION: str = "ap-northeast-2"
    S3_BUCKET_NAME: str = "ticketdiary-images"
    FIREBASE_CREDENTIALS_PATH: str = "./firebase-credentials.json"
    APP_ENV: str = "development"
    APP_DEBUG: bool = True
    CORS_ORIGINS: list[str] = ["http://localhost:3000"]


settings = Settings()
