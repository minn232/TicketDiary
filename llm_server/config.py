from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

_ENV_FILE = Path(__file__).resolve().parent / ".env"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=str(_ENV_FILE), env_file_encoding="utf-8", extra="ignore")

    # 백엔드가 발급한 공유 키. 인바운드(백엔드→이 서버) 요청 검증과
    # 아웃바운드(이 서버→백엔드 콜백) 요청 인증 헤더에 동일하게 사용됨.
    LLM_EXTRACT_API_KEY: str

    # 콜백을 보낼 백엔드 base URL. 끝에 슬래시(/) 없이 입력.
    # 예: https://ticket-diary.com/api/v1 (로컬 테스트 시 http://localhost:8000/api/v1)
    BACKEND_BASE_URL: str = "https://ticket-diary.com/api/v1"

    # 콜백 HTTP 요청 타임아웃(초)
    CALLBACK_TIMEOUT_SECONDS: float = 30.0

    # 처리 완료 ID를 기록하는 SQLite 파일 경로
    DEDUP_DB_PATH: str = "./processed_ids.sqlite3"


settings = Settings()
