import asyncio
import sys
import uuid
from unittest.mock import AsyncMock, MagicMock, patch
from urllib.parse import urlsplit

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport
from sqlalchemy import text

from app.main import app

# Windows에서 asyncio 에러 방지
if sys.platform == 'win32':
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())


# 세션 시작 시 1회, 로컬 dev DB를 깨끗하게 비운다. 이 DB가 실제 dev용으로도 같이 쓰이고
# 테스트 실행마다 데이터가 누적돼서([[flaky_test_fuzzy_artist_match]]의 근본 배경이었음
# - 6000+ concerts 누적으로 아티스트명 퍼지매칭 오탐 확률이 올라감), 매 세션 시작 전에
# 싹 비워서 테스트가 항상 빈 DB에서 시작하게 함.
# host가 localhost/127.0.0.1이 아니면 절대 실행하지 않음 - 실수로 원격/프로덕션 DB를
# 가리키는 상태로 테스트를 돌렸을 때 TRUNCATE가 나가는 참사를 막기 위한 안전장치.
@pytest_asyncio.fixture(scope="session", loop_scope="session", autouse=True)
async def _clean_db_before_session():
    from app.core.config import settings
    from app.core.database import engine

    host = urlsplit(settings.DATABASE_URL.replace("+asyncpg", "")).hostname
    if host not in ("localhost", "127.0.0.1"):
        raise RuntimeError(
            f"DATABASE_URL host가 localhost가 아님({host}) - 안전을 위해 테스트 DB 초기화를 중단합니다. "
            "원격/프로덕션 DB를 가리키고 있는 게 아닌지 확인하세요."
        )

    async with engine.begin() as conn:
        result = await conn.execute(
            text("SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename != 'alembic_version'")
        )
        tables = [row[0] for row in result]
        if tables:
            await conn.execute(text(f"TRUNCATE TABLE {', '.join(tables)} RESTART IDENTITY CASCADE"))

    # 이 픽스처는 세션 스코프 이벤트 루프에서 도는데, 각 테스트는 함수 스코프 이벤트 루프를
    # 쓴다(pytest.ini의 asyncio_default_fixture_loop_scope = function). engine이 여기서
    # 세션 루프에 연결을 맺어두면 이후 테스트들이 다른 루프에서 그 커넥션을 재사용하려다
    # "attached to a different loop" 에러가 남 - 여기서 바로 dispose해서 다음 사용(각
    # 테스트의 함수 스코프 루프) 시 새 커넥션을 새로 맺게 한다(_reset_db_pool과 같은 이유).
    await engine.dispose()
    print(f"\n[conftest] 테스트 세션 시작 전 로컬 DB 초기화 완료 ({len(tables)}개 테이블)")

    yield


# 테스트마다 DB 연결 풀 초기화
@pytest_asyncio.fixture(autouse=True)
async def _reset_db_pool():
    # 테스트 전

    yield

    # 테스트 후 DB 연결 풀 종료
    from app.core.database import engine
    await engine.dispose()


# 테스트마다 인메모리 rate limit 상태 초기화 (get_auth_token 픽스처가 고정 device_id를 써서
# 여러 테스트가 같은 유저를 공유하므로, 안 지우면 한 테스트의 호출 횟수가 다른 테스트에 새어나감)
@pytest.fixture(autouse=True)
def _reset_rate_limits():
    from app.core.deps import _rate_limit_hits
    _rate_limit_hits.clear()
    yield


# 티켓 등록(POST /tickets)이 백그라운드로 Last.fm 장르 즉시 캐싱(ensure_artist_genres_cached)을
# 트리거하는데, 이걸 기본으로 막아두지 않으면 티켓을 만드는 모든 테스트가 로컬 .env의 진짜
# LASTFM_API_KEY로 실제 네트워크 호출을 하게 됨(느려지고, 테스트용 아티스트명이 실제 캐시
# 테이블에 쌓임). fetch_top_tags 자체를 patch하지 않고 API 키만 빈 값으로 덮어써서, 이 함수의
# "키 없으면 빈 리스트" 동작(정상 동작)을 그대로 타게 함 - fetch_top_tags 내부 로직을 직접
# 테스트하는 케이스는 거기서 다시 settings.LASTFM_API_KEY를 patch해서 오버라이드하면 됨
@pytest.fixture(autouse=True)
def _stub_lastfm_genre_fetch():
    with patch("app.services.lastfm.settings.LASTFM_API_KEY", ""):
        yield


# 테스트용 게스트 인증 토큰을 반환하는 픽스처
@pytest_asyncio.fixture
async def get_auth_token():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post("/api/v1/auth/guest", json={"device_id": "fixture-device"})
    return response.json()["access_token"]



# 헬퍼

# 테스트용 토큰 생성 함수
async def _get_token() -> str:
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.post("/api/v1/auth/guest", json={"device_id": uuid.uuid4().hex})
    return response.json()["access_token"]


# kopis_mock 헬퍼
def kopis_mock(content: bytes, status_code: int = 200):
    mock_response = MagicMock()
    mock_response.status_code = status_code
    mock_response.content = content
    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = AsyncMock(return_value=mock_response)
    return patch("app.services.kopis.httpx.AsyncClient", return_value=mock_client)


# GET /notifications가 이제 is_sent=True(실제 발송된 것)만 돌려주도록 바뀜(진짜
# "받은 알림함"으로 만들어달라는 요청). 그래서 "언제/무엇이 예약됐는지" 스케줄링
# 자체를 검증하던 기존 테스트들은 API 대신 이 헬퍼로 DB를 직접 봐야 함.
async def _get_notifications_from_db(token: str) -> list[dict]:
    from app.core.database import AsyncSessionLocal
    from app.models.notification import Notification
    from sqlalchemy import select

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        me_res = await ac.get("/api/v1/auth/me", headers={"Authorization": f"Bearer {token}"})
    user_id = uuid.UUID(me_res.json()["id"])

    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(Notification)
            .where(Notification.user_id == user_id)
            .order_by(Notification.scheduled_at.desc())
        )
        rows = result.scalars().all()

    return [
        {
            "id": str(n.id),
            "type": n.type.value,
            "title": n.title,
            "body": n.body,
            "scheduled_at": n.scheduled_at.isoformat(),
            "is_sent": n.is_sent,
            "is_read": n.is_read,
        }
        for n in rows
    ]
