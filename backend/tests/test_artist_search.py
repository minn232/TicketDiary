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


# 그룹/멤버 관계가 전혀 없는 단독 canonical이라도 실제 공연이 0개면 숨겨야 함(관계 확장 경로가
# 아니어도, 예: MusicBrainz 오매칭 정리 중 안 쓰이게 된 canonical이 남아있는 경우 등)
@pytest.mark.asyncio
async def test_search_artists_hides_standalone_canonical_with_no_concert():
    name = f"공연없는단독_{uuid.uuid4().hex[:8]}"
    async with AsyncSessionLocal() as db:
        canonical = CanonicalArtist(mbid=uuid.uuid4().hex, canonical_name=name)
        db.add(canonical)
        await db.flush()
        db.add(ArtistAlias(canonical_artist_id=canonical.id, alias_text=name, source="musicbrainz"))
        await db.commit()

        results = await search_artists(db, name)

    assert results == []


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
async def test_search_artists_hides_relation_only_group_with_no_concert():
    # 그룹 자체가 어떤 공연에도 원문으로 등장한 적 없으면(멤버 관계로만 존재, 팔로우 매칭용으로만
    # 미리 채워진 경우) 검색 결과에서 빠져야 함(2026-09-11: 이런 관계전용 아티스트가 3천여 개나
    # 쌓여 검색이 지저분해지는 문제로 정책 변경 - 예전엔 이런 것도 노출했었음)
    group_name = f"관계전용그룹_{uuid.uuid4().hex[:8]}"
    member_name = f"멤버_{uuid.uuid4().hex[:8]}"
    async with AsyncSessionLocal() as db:
        await _seed_group_and_member(db, group_name, member_name)
        results = await search_artists(db, group_name)

    assert results == []


@pytest.mark.asyncio
async def test_search_artists_hides_member_and_group_when_neither_has_concert():
    # 멤버도 그룹도 실제 공연이 하나도 없으면(관계로만 존재) 둘 다 검색 결과에서 빠져야 함
    group_name = f"솔로없는그룹_{uuid.uuid4().hex[:8]}"
    member_name = f"솔로없는멤버_{uuid.uuid4().hex[:8]}"
    async with AsyncSessionLocal() as db:
        await _seed_group_and_member(db, group_name, member_name)
        results = await search_artists(db, member_name)

    assert results == []


@pytest.mark.asyncio
async def test_search_artists_shows_member_when_own_concert_but_hides_group_without_one():
    # 멤버는 자기 공연이 있어서 노출되지만, 그룹 자체는 공연이 0개라 여전히 숨겨져야 함
    # (그룹 유무 판단도 has_own_concert를 동일하게 적용)
    token = await _get_token()
    group_name = f"솔로있는그룹_{uuid.uuid4().hex[:8]}"
    member_name = f"솔로있는멤버_{uuid.uuid4().hex[:8]}"
    await _create_concert(f"PF_AS_SOLO_{uuid.uuid4().hex[:6]}", member_name, token)

    async with AsyncSessionLocal() as db:
        await _seed_group_and_member(db, group_name, member_name)
        results = await search_artists(db, member_name)

    assert {r["name"] for r in results} == {member_name}


@pytest.mark.asyncio
async def test_search_artists_group_query_does_not_expand_to_members():
    # 그룹으로 검색했을 땐 멤버 전원이 딸려 나오면 안 됨(요청에 따라 그룹->멤버 확장은 안 함).
    # 그룹 자신은 공연이 있어야 노출되므로(has_own_concert 정책) 그룹 이름으로 실제 콘서트를 만듦
    token = await _get_token()
    group_name = f"멤버비노출그룹_{uuid.uuid4().hex[:8]}"
    member_name = f"안보일멤버_{uuid.uuid4().hex[:8]}"
    await _create_concert(f"PF_AS_GRPQ_{uuid.uuid4().hex[:6]}", group_name, token)

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
