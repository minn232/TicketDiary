from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.batch.scheduler import start_scheduler, stop_scheduler
from app.core.config import settings
from app.core.database import AsyncSessionLocal
from app.api.v1.endpoints.admin import page_router as admin_page_router
from app.api.v1.router import api_router
from app.services.artist_blocklist import refresh_blocklist_cache


# 앱 시작/종료 시 스케줄러 실행 및 중지, 관리자 페이지가 추가한 블록리스트를 인메모리로 로드
@asynccontextmanager
async def lifespan(app: FastAPI):
    async with AsyncSessionLocal() as db:
        await refresh_blocklist_cache(db)
    start_scheduler()
    yield
    stop_scheduler()


# DEBUG 모드일 때만 /docs 노출
app = FastAPI(
    title="Ticket Diary API",
    version="0.1.0",
    docs_url="/docs" if settings.APP_DEBUG else None,
    lifespan=lifespan,
)

# CORS 설정 (프론트 도메인 허용)
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# API 라우터 등록
app.include_router(api_router, prefix="/api/v1")
# 관리자 페이지 - Nginx가 admin 서브도메인을 /admin으로 프록시하는 걸 전제로 루트 경로에 마운트
app.include_router(admin_page_router, prefix="/admin")


# 헬스 체크
@app.get("/health")
async def health_check():
    return {"status": "ok"}
