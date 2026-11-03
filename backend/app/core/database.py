from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine, async_sessionmaker
from sqlalchemy.orm import DeclarativeBase
from app.core.config import settings

# 기본값(5+10)은 외부 API를 기다리는 작업이 몰리면 금방 바닥나서 여유를 둠 - Postgres max_connections 100에서
# 배치 스크립트·psql 몫을 남기고 30까지. 근본 대책은 외부 호출 동안 연결을 안 쥐는 것(deps.get_current_user 등)
engine = create_async_engine(settings.DATABASE_URL, echo=settings.APP_DEBUG, pool_size=10, max_overflow=20)
AsyncSessionLocal = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


async def get_db():
    async with AsyncSessionLocal() as session:
        yield session
