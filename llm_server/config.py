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

    # vLLM OpenAI 호환 서버 주소. 이 프로세스(FastAPI 래퍼)와 같은 인스턴스에서 뜨지만
    # 포트가 겹치면 안 됨 - vLLM이 8000번을 쓰기로 확정됐으므로 이 래퍼는 8001번으로
    # 띄울 것(uvicorn main:app --port 8001)
    VLLM_BASE_URL: str = "http://localhost:8000/v1"
    # vLLM은 보통 임의 문자열이면 충분
    VLLM_API_KEY: str = "EMPTY"

    # 배치 처리 시 모델 호출을 동시에 몇 건까지 허용할지 (crawl/artist/diary 배치 전부
    # 공유하는 값 - 셋 다 결국 같은 GPU/vLLM 인스턴스를 두고 경쟁하기 때문). 평소
    # 트래픽(하루 수십 건)은 기본값으로도 충분하고, 최초 아티스트 백필처럼 한 번에
    # 수천 건을 몰아서 보낼 때만 일시적으로 올리는 용도. vLLM 쪽 GPU 메모리 여유에
    # 따라 감당 가능한 동시 요청 수가 다르므로, 낮은 값으로 먼저 테스트하고 점진적으로
    # 올릴 것 (너무 높이면 vLLM이 OOM 날 수 있음).
    BATCH_CONCURRENCY: int = 3


settings = Settings()
