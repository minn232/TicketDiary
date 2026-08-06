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
    REFRESH_TOKEN_EXPIRE_DAYS: int = 30
    KAKAO_REST_API_KEY: str = ""
    KAKAO_REDIRECT_URI: str = ""
    KAKAO_CLIENT_SECRET: str = ""
    KOPIS_API_KEY: str = ""
    KOPIS_BASE_URL: str = "http://www.kopis.or.kr/openApi/restful"
    SETLISTFM_API_KEY: str = ""
    SETLISTFM_BASE_URL: str = "https://api.setlist.fm/rest/1.0"
    LASTFM_API_KEY: str = ""
    LASTFM_BASE_URL: str = "https://ws.audioscrobbler.com/2.0"
    GOOGLE_VISION_API_KEY: str = ""
    # LLM_EXTRACT_URL: str = ""  # OCR 파싱이 로컬 regex로 전환되어 현재 미사용
    LLM_EXTRACT_API_KEY: str = ""
    LLM_CRAWL_URL: str = ""
    LLM_ARTIST_URL: str = ""
    LLM_DIARY_URL: str = ""
    # LLM팀 GPU pod을 매일 켜고 끄기 위한 RunPod REST API 인증 정보 (비용 절감용, 미설정 시 트리거 안 함)
    RUNPOD_API_KEY: str = ""
    RUNPOD_POD_ID: str = ""
    # pod을 깨운 뒤 SSH로 접속해서 start_all.sh(vLLM+llm_server+cloudflared 기동)를 원격
    # 실행하기 위한 정보. RUNPOD_SSH_HOST 미설정이면 pod만 켜고 원격 실행은 건너뜀
    RUNPOD_SSH_HOST: str = ""
    RUNPOD_SSH_PORT: int = 22
    RUNPOD_SSH_USER: str = "root"
    RUNPOD_SSH_KEY_PATH: str = ""
    AWS_ACCESS_KEY_ID: str = ""
    AWS_SECRET_ACCESS_KEY: str = ""
    AWS_REGION: str = "ap-northeast-2"
    S3_BUCKET_NAME: str = "ticketdiary-images"
    FIREBASE_CREDENTIALS_PATH: str = "./firebase-credentials.json"
    APP_ENV: str = "development"
    APP_DEBUG: bool = True
    CORS_ORIGINS: list[str] = ["http://localhost:3000"]


settings = Settings()
