import uuid
from unittest.mock import AsyncMock, patch

import pytest
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from app.core.database import AsyncSessionLocal
from app.main import app
from app.models.artist_normalization import ArtistAlias, ArtistGroupMembership, CanonicalArtist
from app.services.artist_normalization import try_link_canonical_to_musicbrainz
from app.services.musicbrainz import ArtistCandidate, BandRelation
from conftest import _get_token, kopis_mock


def _kr_candidate(name: str, score: int = 100) -> ArtistCandidate:
    return ArtistCandidate(mbid=uuid.uuid4().hex, name=name, score=score, country="KR", source="country_kr")

_ADMIN_KEY = "test-admin-key"


def _admin_headers():
    return {"X-Admin-Key": _ADMIN_KEY}


def _admin_settings():
    return patch("app.core.deps.settings.ADMIN_API_KEY", _ADMIN_KEY)


def _make_detail_xml(kopis_id: str, artist: str) -> bytes:
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f"<dbs><db>"
        f"<mt20id>{kopis_id}</mt20id>"
        f"<prfnm>{kopis_id} 공연</prfnm>"
        f"<prfpdfrom>2030.06.01</prfpdfrom>"
        f"<prfpdto>2030.06.30</prfpdto>"
        f"<fcltynm>테스트공연장</fcltynm>"
        f"<poster>https://example.com/poster.jpg</poster>"
        f"<genrenm>대중음악</genrenm>"
        f"<prfcast>{artist}</prfcast>"
        f"<pcseguidance></pcseguidance>"
        f"<sty></sty>"
        f"</db></dbs>"
    ).encode("utf-8")


async def _create_concert(kopis_id: str, artist: str) -> str:
    token = await _get_token()
    with kopis_mock(_make_detail_xml(kopis_id, artist)):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.get(f"/api/v1/concerts/{kopis_id}", headers={"Authorization": f"Bearer {token}"})
    assert res.status_code == 200
    return res.json()["id"]


@pytest.mark.asyncio
async def test_admin_requires_key():
    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.get("/api/v1/admin/concerts")
    assert res.status_code == 401


@pytest.mark.asyncio
async def test_admin_rejects_wrong_key():
    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.get("/api/v1/admin/concerts", headers={"X-Admin-Key": "wrong"})
    assert res.status_code == 401


@pytest.mark.asyncio
async def test_admin_lists_and_searches_concerts():
    name = f"어드민목록테스트_{uuid.uuid4().hex[:6]}"
    concert_id = await _create_concert(f"PF_ADMIN_LIST_{uuid.uuid4().hex[:6]}", name)

    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.get(
                "/api/v1/admin/concerts", params={"search": name, "flagged_only": False}, headers=_admin_headers()
            )
    assert res.status_code == 200
    data = res.json()
    assert any(item["id"] == concert_id for item in data["items"])


@pytest.mark.asyncio
async def test_admin_get_detail_includes_statuses():
    name = f"어드민상세_{uuid.uuid4().hex[:6]}"
    concert_id = await _create_concert(f"PF_ADMIN_DETAIL_{uuid.uuid4().hex[:6]}", name)

    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.get(f"/api/v1/admin/concerts/{concert_id}", headers=_admin_headers())
    assert res.status_code == 200
    data = res.json()
    assert data["artist_name"] == [name]
    assert "ticketing_links" in data
    assert isinstance(data["statuses"], list)


@pytest.mark.asyncio
async def test_admin_renames_artist():
    original = f"수정전_{uuid.uuid4().hex[:6]}"
    concert_id = await _create_concert(f"PF_ADMIN_RENAME_{uuid.uuid4().hex[:6]}", original)

    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.patch(
                f"/api/v1/admin/concerts/{concert_id}/artist-name",
                json={"original_name": original, "confirmed_name": "수정후이름"},
                headers=_admin_headers(),
            )
    assert res.status_code == 200
    assert res.json()["artist_name"] == ["수정후이름"]


@pytest.mark.asyncio
async def test_admin_deletes_artist():
    m1, m2 = f"멤버A_{uuid.uuid4().hex[:6]}", f"멤버B_{uuid.uuid4().hex[:6]}"
    concert_id = await _create_concert(f"PF_ADMIN_DELETE_{uuid.uuid4().hex[:6]}", f"{m1},{m2}")

    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.delete(
                f"/api/v1/admin/concerts/{concert_id}/artist-name", params={"name": m1}, headers=_admin_headers()
            )
    assert res.status_code == 200
    assert res.json()["artist_name"] == [m2]


@pytest.mark.asyncio
async def test_admin_adds_missing_artist():
    concert_id = await _create_concert(f"PF_ADMIN_ADD_{uuid.uuid4().hex[:6]}", "기존아티스트")
    new_name = f"놓친아티스트_{uuid.uuid4().hex[:6]}"

    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/admin/concerts/{concert_id}/artist-name",
                json={"name": new_name},
                headers=_admin_headers(),
            )
    assert res.status_code == 200
    assert set(res.json()["artist_name"]) == {"기존아티스트", new_name}


@pytest.mark.asyncio
async def test_admin_add_rejects_duplicate():
    concert_id = await _create_concert(f"PF_ADMIN_ADDDUP_{uuid.uuid4().hex[:6]}", "이미있는아티스트")

    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/admin/concerts/{concert_id}/artist-name",
                json={"name": "이미있는아티스트"},
                headers=_admin_headers(),
            )
    assert res.status_code == 400


# 신규 canonical(mbid=None)이면 응답 이후 MusicBrainz 연결을 백그라운드로 시도하는지 -
# conftest의 autouse 스텁을 이 테스트에서만 해제하고 호출 여부를 직접 검증

@pytest.mark.asyncio
async def test_admin_add_schedules_musicbrainz_link_for_new_canonical():
    concert_id = await _create_concert(f"PF_ADMIN_LINK_{uuid.uuid4().hex[:6]}", "기존아티스트")
    new_name = f"새아티스트_{uuid.uuid4().hex[:6]}"

    mock_link = AsyncMock()
    with _admin_settings(), patch("app.api.v1.endpoints.admin.try_link_canonical_to_musicbrainz", new=mock_link):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/admin/concerts/{concert_id}/artist-name",
                json={"name": new_name},
                headers=_admin_headers(),
            )
    assert res.status_code == 200
    mock_link.assert_awaited_once()

    async with AsyncSessionLocal() as db:
        canonical = (
            await db.execute(select(CanonicalArtist).where(CanonicalArtist.canonical_name == new_name))
        ).scalar_one()
    mock_link.assert_awaited_once_with(canonical.id)


@pytest.mark.asyncio
async def test_admin_add_skips_musicbrainz_link_when_already_linked():
    existing_name = f"이미연결됨_{uuid.uuid4().hex[:6]}"
    async with AsyncSessionLocal() as db:
        db.add(CanonicalArtist(mbid=uuid.uuid4().hex, canonical_name=existing_name))
        await db.commit()

    concert_id = await _create_concert(f"PF_ADMIN_NOLINK_{uuid.uuid4().hex[:6]}", "기존아티스트")

    mock_link = AsyncMock()
    with _admin_settings(), patch("app.api.v1.endpoints.admin.try_link_canonical_to_musicbrainz", new=mock_link):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/admin/concerts/{concert_id}/artist-name",
                json={"name": existing_name},
                headers=_admin_headers(),
            )
    assert res.status_code == 200
    mock_link.assert_not_called()  # 이미 mbid가 있는 canonical이라 재조회 안 함


# try_link_canonical_to_musicbrainz 자체 - 매치되면 mbid+관계까지 채우고, 안 되면 그대로 둠

@pytest.mark.asyncio
async def test_try_link_canonical_sets_mbid_and_relations_on_match():
    name = f"관리자밴드_{uuid.uuid4().hex[:6]}"
    async with AsyncSessionLocal() as db:
        canonical = CanonicalArtist(mbid=None, canonical_name=name)
        db.add(canonical)
        await db.commit()
        canonical_id = canonical.id

    relations = [BandRelation(mbid=uuid.uuid4().hex, name="현역멤버", type="Person", is_current=True)]
    with patch(
        "app.services.artist_normalization.search_artist", new=AsyncMock(return_value=[_kr_candidate(name)])
    ), patch(
        "app.services.artist_normalization.fetch_member_of_band_relations", new=AsyncMock(return_value=relations)
    ), patch(
        "app.services.artist_normalization.fetch_wikidata_qid", new=AsyncMock(return_value="Q1")
    ), patch(
        "app.services.artist_normalization.fetch_korean_label", new=AsyncMock(return_value=f"한글{name}")
    ):
        await try_link_canonical_to_musicbrainz(canonical_id)

    async with AsyncSessionLocal() as db:
        canonical = await db.get(CanonicalArtist, canonical_id)
        assert canonical.mbid is not None
        assert canonical.canonical_name == name  # admin이 정한 표기는 안 바뀜

        memberships = (
            await db.execute(
                select(ArtistGroupMembership).where(ArtistGroupMembership.group_canonical_id == canonical_id)
            )
        ).scalars().all()
        assert len(memberships) == 1  # 관계까지 채워짐

        alias_rows = (
            await db.execute(select(ArtistAlias).where(ArtistAlias.canonical_artist_id == canonical_id))
        ).scalars().all()
        wikidata_alias = next(a for a in alias_rows if a.source == "wikidata")
        assert wikidata_alias.alias_text == f"한글{name}"  # Wikidata 별칭도 같이 채워짐


@pytest.mark.asyncio
async def test_try_link_canonical_leaves_mbid_none_when_unmatched():
    name = f"매치안됨_{uuid.uuid4().hex[:6]}"
    async with AsyncSessionLocal() as db:
        canonical = CanonicalArtist(mbid=None, canonical_name=name)
        db.add(canonical)
        await db.commit()
        canonical_id = canonical.id

    with patch("app.services.artist_normalization.search_artist", new=AsyncMock(return_value=[])):
        await try_link_canonical_to_musicbrainz(canonical_id)

    async with AsyncSessionLocal() as db:
        canonical = await db.get(CanonicalArtist, canonical_id)
        assert canonical.mbid is None  # 매치 안 됐으니 그대로


# DELETE ?blocklist=true - 삭제와 동시에 배포 없이 즉시 차단 목록에 등록되는지

@pytest.mark.asyncio
async def test_admin_delete_with_blocklist_prevents_future_reuse():
    from app.services.artist_blocklist import is_blocklisted_artist_name

    bad_name = f"기관명오추출_{uuid.uuid4().hex[:6]}"
    concert_id = await _create_concert(f"PF_ADMIN_BLOCK_{uuid.uuid4().hex[:6]}", bad_name)
    assert is_blocklisted_artist_name(bad_name) is False

    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.delete(
                f"/api/v1/admin/concerts/{concert_id}/artist-name",
                params={"name": bad_name, "blocklist": True},
                headers=_admin_headers(),
            )
    assert res.status_code == 200
    assert res.json()["artist_name"] == []
    assert is_blocklisted_artist_name(bad_name) is True  # 재배포 없이 바로 반영
