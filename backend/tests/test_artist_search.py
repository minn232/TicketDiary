import uuid

import pytest
from httpx import AsyncClient, ASGITransport

from app.core.database import AsyncSessionLocal
from app.main import app
from app.models.artist_normalization import ArtistAlias, ArtistGroupMembership, CanonicalArtist
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


# 멤버-그룹 관계 처리

async def _seed_group_and_member(db, group_name: str, member_name: str) -> None:
    group = CanonicalArtist(mbid=uuid.uuid4().hex, canonical_name=group_name)
    db.add(group)
    await db.flush()
    db.add(ArtistAlias(canonical_artist_id=group.id, alias_text=group_name, source="musicbrainz"))

    member = CanonicalArtist(mbid=uuid.uuid4().hex, canonical_name=member_name)
    db.add(member)
    await db.flush()
    db.add(ArtistAlias(canonical_artist_id=member.id, alias_text=member_name, source="musicbrainz"))
    db.add(ArtistGroupMembership(member_canonical_id=member.id, group_canonical_id=group.id, is_current=True))
    await db.commit()


@pytest.mark.asyncio
async def test_search_artists_finds_relation_only_group_with_no_concert():
    # 그룹 자체가 어떤 공연에도 원문으로 등장한 적 없어도(멤버 관계로만 존재, JYJ류) canonical_name
    # 검색으로는 찾을 수 있어야 함
    group_name = f"관계전용그룹_{uuid.uuid4().hex[:8]}"
    member_name = f"멤버_{uuid.uuid4().hex[:8]}"
    async with AsyncSessionLocal() as db:
        await _seed_group_and_member(db, group_name, member_name)
        results = await search_artists(db, group_name)

    assert [r["name"] for r in results] == [group_name]


@pytest.mark.asyncio
async def test_search_artists_hides_member_without_own_concert_shows_group_instead():
    # 멤버 자기 이름으로 등록된 공연이 하나도 없으면(밴드 공연에만 라인업으로 존재) 멤버는
    # 숨기고 그룹만 노출
    group_name = f"솔로없는그룹_{uuid.uuid4().hex[:8]}"
    member_name = f"솔로없는멤버_{uuid.uuid4().hex[:8]}"
    async with AsyncSessionLocal() as db:
        await _seed_group_and_member(db, group_name, member_name)
        results = await search_artists(db, member_name)

    assert [r["name"] for r in results] == [group_name]


@pytest.mark.asyncio
async def test_search_artists_shows_both_member_and_group_when_member_has_own_concert():
    token = await _get_token()
    group_name = f"솔로있는그룹_{uuid.uuid4().hex[:8]}"
    member_name = f"솔로있는멤버_{uuid.uuid4().hex[:8]}"
    await _create_concert(f"PF_AS_SOLO_{uuid.uuid4().hex[:6]}", member_name, token)

    async with AsyncSessionLocal() as db:
        await _seed_group_and_member(db, group_name, member_name)
        results = await search_artists(db, member_name)

    assert {r["name"] for r in results} == {member_name, group_name}


@pytest.mark.asyncio
async def test_search_artists_group_query_does_not_expand_to_members():
    # 그룹으로 검색했을 땐 멤버 전원이 딸려 나오면 안 됨(요청에 따라 그룹->멤버 확장은 안 함)
    group_name = f"멤버비노출그룹_{uuid.uuid4().hex[:8]}"
    member_name = f"안보일멤버_{uuid.uuid4().hex[:8]}"
    async with AsyncSessionLocal() as db:
        await _seed_group_and_member(db, group_name, member_name)
        results = await search_artists(db, group_name)

    assert [r["name"] for r in results] == [group_name]


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
