import uuid

import pytest
from sqlalchemy import select

from app.core.database import AsyncSessionLocal
from app.models.artist_blocklist import BlockedArtistName
from app.services.artist_blocklist import add_to_blocklist, is_blocklisted_artist_name, refresh_blocklist_cache
from app.services.artist_matching import normalize_artist_names


def test_exact_match_blocked():
    assert is_blocklisted_artist_name("NOL") is True


def test_whitespace_and_case_variants_blocked():
    assert is_blocklisted_artist_name("  nol  ") is True
    assert is_blocklisted_artist_name("Various   Artists") is True


def test_real_artist_name_not_blocked():
    assert is_blocklisted_artist_name("10cm") is False


def test_substring_of_blocklisted_name_not_blocked():
    # exact match만 하므로 블록리스트 문자열을 부분 포함하는 실제 아티스트명은 안 걸림
    assert is_blocklisted_artist_name("NOLGAE") is False


def test_normalize_artist_names_filters_blocklisted_entries():
    result = normalize_artist_names(["NOL", "진짜아티스트", "Various Artists"])
    assert result == ["진짜아티스트"]


def test_normalize_artist_names_blocklisted_name_not_added_to_known_names():
    known: set[str] = set()
    normalize_artist_names(["KIMCHIKURA"], known)
    assert known == set()


# add_to_blocklist/refresh_blocklist_cache - 관리자 페이지가 배포 없이 즉시 차단을 추가하는 경로

@pytest.mark.asyncio
async def test_add_to_blocklist_persists_and_updates_cache_immediately():
    name = f"오탐아티스트_{uuid.uuid4().hex[:6]}"
    assert is_blocklisted_artist_name(name) is False

    async with AsyncSessionLocal() as db:
        await add_to_blocklist(db, name)

    assert is_blocklisted_artist_name(name) is True  # DB 커밋 직후 바로(재시작 없이) 반영

    async with AsyncSessionLocal() as db:
        row = (
            await db.execute(select(BlockedArtistName).where(BlockedArtistName.name == name))
        ).scalar_one()
    assert row.source == "admin"


@pytest.mark.asyncio
async def test_add_to_blocklist_skips_duplicate():
    name = f"중복차단_{uuid.uuid4().hex[:6]}"
    async with AsyncSessionLocal() as db:
        await add_to_blocklist(db, name)
        await add_to_blocklist(db, name)  # 두 번째는 조용히 무시(유니크 제약 위반 없이)

    async with AsyncSessionLocal() as db:
        rows = (
            await db.execute(select(BlockedArtistName).where(BlockedArtistName.name == name))
        ).scalars().all()
    assert len(rows) == 1


@pytest.mark.asyncio
async def test_refresh_blocklist_cache_loads_existing_db_entries():
    name = f"서버재시작복원_{uuid.uuid4().hex[:6]}"
    async with AsyncSessionLocal() as db:
        db.add(BlockedArtistName(name=name, source="admin"))
        await db.commit()

    assert is_blocklisted_artist_name(name) is False  # 아직 캐시 갱신 전(서버 재시작 직후를 재현)

    async with AsyncSessionLocal() as db:
        await refresh_blocklist_cache(db)

    assert is_blocklisted_artist_name(name) is True
