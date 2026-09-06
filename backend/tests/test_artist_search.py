import uuid

import pytest
from httpx import AsyncClient, ASGITransport

from app.core.database import AsyncSessionLocal
from app.main import app
from app.models.artist_normalization import ArtistAlias, CanonicalArtist
from app.services.artist_search import search_artists
from conftest import _get_token, kopis_mock


def _make_detail_xml(kopis_id: str, artist: str) -> bytes:
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f"<dbs><db>"
        f"<mt20id>{kopis_id}</mt20id>"
        f"<prfnm>{kopis_id} 공연</prfnm>"
        f"<prfpdfrom>2020.06.01</prfpdfrom>"
        f"<prfpdto>2020.06.30</prfpdto>"
        f"<fcltynm>테스트공연장</fcltynm>"
        f"<poster>https://example.com/poster.jpg</poster>"
        f"<genrenm>대중음악</genrenm>"
        f"<prfcast>{artist}</prfcast>"
        f"<pcseguidance></pcseguidance>"
        f"<sty></sty>"
        f"</db></dbs>"
    ).encode("utf-8")


# KOPIS mock으로 (이미 종료된) 공연 상세 조회 후 concert_id 반환 - DB 검색이 KOPIS 실시간
# 검색과 달리 종료 공연도 찾아내는지 확인하는 게 이 테스트 파일의 핵심이라 일부러 과거 날짜로 등록
async def _create_concert(kopis_id: str, artist: str, token: str) -> str:
    with kopis_mock(_make_detail_xml(kopis_id, artist)):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.get(f"/api/v1/concerts/{kopis_id}", headers={"Authorization": f"Bearer {token}"})
    assert res.status_code == 200
    return res.json()["id"]


@pytest.mark.asyncio
async def test_search_artists_finds_artist_with_only_ended_concert():
    token = await _get_token()
    artist = f"종료된아티스트_{uuid.uuid4().hex[:8]}"
    await _create_concert(f"PF_AS_ENDED_{uuid.uuid4().hex[:6]}", artist, token)

    async with AsyncSessionLocal() as db:
        results = await search_artists(db, artist)

    assert [r["name"] for r in results] == [artist]
    assert results[0]["profile_image_url"] is None


@pytest.mark.asyncio
async def test_search_artists_is_case_insensitive_and_partial():
    token = await _get_token()
    artist = f"CaseTest{uuid.uuid4().hex[:8]}"
    await _create_concert(f"PF_AS_CASE_{uuid.uuid4().hex[:6]}", artist, token)

    async with AsyncSessionLocal() as db:
        results = await search_artists(db, artist.lower()[:8])

    assert artist in [r["name"] for r in results]


@pytest.mark.asyncio
async def test_search_artists_ranks_exact_substring_match_before_others():
    token = await _get_token()
    query = f"랭크{uuid.uuid4().hex[:6]}"
    exact = query
    longer = f"{query}인디밴드"
    await _create_concert(f"PF_AS_RANK_A_{uuid.uuid4().hex[:6]}", f"{exact},{longer}", token)

    async with AsyncSessionLocal() as db:
        results = await search_artists(db, query)

    names = [r["name"] for r in results]
    assert names.index(exact) < names.index(longer)


@pytest.mark.asyncio
async def test_search_artists_attaches_profile_image_when_normalized():
    token = await _get_token()
    artist = f"사진있음_{uuid.uuid4().hex[:8]}"
    await _create_concert(f"PF_AS_IMG_{uuid.uuid4().hex[:6]}", artist, token)

    async with AsyncSessionLocal() as db:
        canonical = CanonicalArtist(
            mbid=uuid.uuid4().hex, canonical_name=artist, profile_image_url="https://img.example.com/a.jpg"
        )
        db.add(canonical)
        await db.flush()
        db.add(ArtistAlias(canonical_artist_id=canonical.id, alias_text=artist, source="musicbrainz"))
        await db.commit()

        results = await search_artists(db, artist)

    assert results[0]["name"] == artist
    assert results[0]["profile_image_url"] == "https://img.example.com/a.jpg"


@pytest.mark.asyncio
async def test_search_artists_blank_query_returns_empty():
    async with AsyncSessionLocal() as db:
        assert await search_artists(db, "   ") == []


@pytest.mark.asyncio
async def test_search_artists_endpoint_returns_results():
    token = await _get_token()
    artist = f"엔드포인트_{uuid.uuid4().hex[:8]}"
    await _create_concert(f"PF_AS_EP_{uuid.uuid4().hex[:6]}", artist, token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get(
            "/api/v1/artists/search", params={"q": artist}, headers={"Authorization": f"Bearer {token}"}
        )

    assert res.status_code == 200
    body = res.json()
    assert [r["name"] for r in body["results"]] == [artist]
