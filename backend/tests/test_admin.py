import uuid
from unittest.mock import AsyncMock, patch

import pytest
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from app.core.database import AsyncSessionLocal
from app.main import app
from app.models.artist_normalization import ArtistAlias, ArtistGroupMembership, CanonicalArtist
from app.models.concert import Concert
from app.services.artist_normalization import _collapse_members_to_group_names, try_link_canonical_to_musicbrainz
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


# unsent_to_llm_only 필터 - send_posters_for_artist_extraction 대상이 아닌(=포스터 LLM
# 추출이 영영 안 오는) 공연만 골라내는지, 사유(llm_exclusion_reasons)도 맞게 나오는지 테스트
@pytest.mark.asyncio
async def test_admin_unsent_to_llm_only_filters_by_artist_count():
    eligible_name = f"어드민LLM대상_{uuid.uuid4().hex[:6]}"
    eligible_id = await _create_concert(f"PF_ADMIN_LLM_OK_{uuid.uuid4().hex[:6]}", eligible_name)

    members = [f"멤버{i}_{uuid.uuid4().hex[:6]}" for i in range(4)]
    excluded_id = await _create_concert(f"PF_ADMIN_LLM_NG_{uuid.uuid4().hex[:6]}", ",".join(members))

    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.get(
                "/api/v1/admin/concerts",
                params={"unsent_to_llm_only": True, "page_size": 100},
                headers=_admin_headers(),
            )
    assert res.status_code == 200
    items = {item["id"]: item for item in res.json()["items"]}
    assert excluded_id in items
    assert eligible_id not in items
    assert "아티스트 4명 이상" in items[excluded_id]["llm_exclusion_reasons"]


# 포스터가 없는 공연도 같은 필터에 걸리고 사유가 정확히 구분되는지 테스트
@pytest.mark.asyncio
async def test_admin_llm_exclusion_reasons_report_missing_poster():
    name = f"포스터없음_{uuid.uuid4().hex[:6]}"
    concert_id = await _create_concert(f"PF_ADMIN_LLM_NOPOSTER_{uuid.uuid4().hex[:6]}", name)

    async with AsyncSessionLocal() as db:
        concert = await db.get(Concert, uuid.UUID(concert_id))
        concert.poster_url = None
        await db.commit()

    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.get(
                "/api/v1/admin/concerts",
                params={"unsent_to_llm_only": True, "search": name},
                headers=_admin_headers(),
            )
    assert res.status_code == 200
    items = res.json()["items"]
    assert len(items) == 1
    assert items[0]["llm_exclusion_reasons"] == ["포스터 없음"]


# "밴드명 + 멤버 여러 명"이 개별 표기로 뽑힌 공연을 밴드명으로 접고 멤버 관계를 등록하는 기능 테스트
@pytest.mark.asyncio
async def test_admin_group_membership_collapses_names_and_registers_relation():
    group = f"밴드_{uuid.uuid4().hex[:6]}"
    m1, m2 = f"멤버1_{uuid.uuid4().hex[:6]}", f"멤버2_{uuid.uuid4().hex[:6]}"
    concert_id = await _create_concert(f"PF_ADMIN_GROUP_{uuid.uuid4().hex[:6]}", f"{group},{m1},{m2}")

    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/admin/concerts/{concert_id}/group-membership",
                json={"group_name": group, "member_names": [m1, m2]},
                headers=_admin_headers(),
            )
    assert res.status_code == 200
    data = res.json()
    assert data["artist_name"] == [group]
    assert data["group_memberships"][group] == sorted([m1, m2])

    async with AsyncSessionLocal() as db:
        group_canonical = (
            await db.execute(select(CanonicalArtist).where(CanonicalArtist.canonical_name == group))
        ).scalar_one()
        rows = (
            await db.execute(
                select(ArtistGroupMembership).where(ArtistGroupMembership.group_canonical_id == group_canonical.id)
            )
        ).scalars().all()
    assert len(rows) == 2
    assert all(r.source == "admin" for r in rows)


# 이 공연에 없는 이름을 멤버로 넘기면 거절돼야 함(오타/다른 공연 표기 혼입 방지)
@pytest.mark.asyncio
async def test_admin_group_membership_rejects_member_not_in_concert():
    group = f"밴드_{uuid.uuid4().hex[:6]}"
    concert_id = await _create_concert(f"PF_ADMIN_GROUP_BAD_{uuid.uuid4().hex[:6]}", group)

    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/admin/concerts/{concert_id}/group-membership",
                json={"group_name": group, "member_names": ["이_공연에없는이름"]},
                headers=_admin_headers(),
            )
    assert res.status_code == 400


# 여기서 등록한 관계가 전역이라, 이후 다른 공연에서 같은 멤버 전원이 밴드명 없이 뽑혀도
# 기존 자동 정리(_collapse_members_to_group_names)가 밴드명으로 접어주는지 - 이 기능의 핵심 가치
@pytest.mark.asyncio
async def test_admin_group_membership_benefits_future_concerts_auto_collapse():
    group = f"밴드나중_{uuid.uuid4().hex[:6]}"
    m1, m2 = f"멤버A_{uuid.uuid4().hex[:6]}", f"멤버B_{uuid.uuid4().hex[:6]}"
    first_id = await _create_concert(f"PF_ADMIN_GROUP_FIRST_{uuid.uuid4().hex[:6]}", f"{group},{m1},{m2}")

    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.post(
                f"/api/v1/admin/concerts/{first_id}/group-membership",
                json={"group_name": group, "member_names": [m1, m2]},
                headers=_admin_headers(),
            )

    second_id = await _create_concert(f"PF_ADMIN_GROUP_SECOND_{uuid.uuid4().hex[:6]}", f"{m1},{m2}")
    async with AsyncSessionLocal() as db:
        await _collapse_members_to_group_names(db, uuid.UUID(second_id))
        await db.commit()
        concert = await db.get(Concert, uuid.UUID(second_id))
    assert concert.artist_name == [group]


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
    ), patch(
        "app.services.artist_normalization._register_artist_image", new=AsyncMock(return_value=None)
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


# GET/PATCH /canonical-artist - admin이 표시명 후보를 보고 직접 고르는 엔드포인트

@pytest.mark.asyncio
async def test_get_canonical_artist_options_endpoint():
    latin_name = f"David{uuid.uuid4().hex[:6]}"
    hangul_name = f"데이비드{uuid.uuid4().hex[:4]}"
    async with AsyncSessionLocal() as db:
        canonical = CanonicalArtist(mbid=uuid.uuid4().hex, canonical_name=latin_name)
        db.add(canonical)
        await db.flush()
        db.add(ArtistAlias(canonical_artist_id=canonical.id, alias_text=hangul_name, source="wikidata"))
        await db.commit()
        canonical_id = canonical.id

    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.get(
                "/api/v1/admin/canonical-artist", params={"name": latin_name}, headers=_admin_headers()
            )
    assert res.status_code == 200
    body = res.json()
    assert body["canonical_id"] == str(canonical_id)
    assert body["current"] == latin_name  # display_name 미설정이라 canonical_name이 그대로 현재값
    texts = {o["text"] for o in body["options"]}
    assert texts == {latin_name, hangul_name}


@pytest.mark.asyncio
async def test_get_canonical_artist_options_404_for_unmatched_name():
    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.get(
                "/api/v1/admin/canonical-artist",
                params={"name": f"매칭안됨_{uuid.uuid4().hex[:6]}"},
                headers=_admin_headers(),
            )
    assert res.status_code == 404


@pytest.mark.asyncio
async def test_patch_canonical_artist_display_name_endpoint():
    latin_name = f"David{uuid.uuid4().hex[:6]}"
    hangul_name = f"데이비드{uuid.uuid4().hex[:4]}"
    async with AsyncSessionLocal() as db:
        canonical = CanonicalArtist(mbid=uuid.uuid4().hex, canonical_name=latin_name)
        db.add(canonical)
        await db.commit()
        canonical_id = canonical.id

    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.patch(
                f"/api/v1/admin/canonical-artist/{canonical_id}/display-name",
                json={"display_name": hangul_name},
                headers=_admin_headers(),
            )
    assert res.status_code == 200
    body = res.json()
    assert body["display_name"] == hangul_name
    assert body["current"] == hangul_name


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


# admin_reviewed_at 검수 상태 - 처음엔 미검수(None), 수정하면 자동으로 검수됨을 확인

@pytest.mark.asyncio
async def test_admin_new_concert_starts_unreviewed():
    concert_id = await _create_concert(f"PF_ADMIN_UNREVIEWED_{uuid.uuid4().hex[:6]}", "아무개")
    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.get(f"/api/v1/admin/concerts/{concert_id}", headers=_admin_headers())
    assert res.json()["admin_reviewed_at"] is None


@pytest.mark.asyncio
async def test_admin_rename_auto_marks_reviewed():
    original = f"검수전_{uuid.uuid4().hex[:6]}"
    concert_id = await _create_concert(f"PF_ADMIN_REVIEW_RENAME_{uuid.uuid4().hex[:6]}", original)

    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.patch(
                f"/api/v1/admin/concerts/{concert_id}/artist-name",
                json={"original_name": original, "confirmed_name": "검수후이름"},
                headers=_admin_headers(),
            )
    assert res.json()["admin_reviewed_at"] is not None


# 이미 맞다고 판단해서 아무것도 안 고치고 "검수 완료"만 누르는 경우
@pytest.mark.asyncio
async def test_admin_review_endpoint_marks_reviewed_without_edit():
    concert_id = await _create_concert(f"PF_ADMIN_REVIEW_ONLY_{uuid.uuid4().hex[:6]}", "이미맞음")

    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(f"/api/v1/admin/concerts/{concert_id}/review", headers=_admin_headers())
    assert res.status_code == 200
    assert res.json()["admin_reviewed_at"] is not None
    assert res.json()["artist_name"] == ["이미맞음"]  # 내용은 그대로


@pytest.mark.asyncio
async def test_admin_unreviewed_only_filter():
    reviewed_name = f"검수됨_{uuid.uuid4().hex[:6]}"
    unreviewed_name = f"검수안됨_{uuid.uuid4().hex[:6]}"
    reviewed_id = await _create_concert(f"PF_ADMIN_UNREV_A_{uuid.uuid4().hex[:6]}", reviewed_name)
    unreviewed_id = await _create_concert(f"PF_ADMIN_UNREV_B_{uuid.uuid4().hex[:6]}", unreviewed_name)

    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.post(f"/api/v1/admin/concerts/{reviewed_id}/review", headers=_admin_headers())
            res = await ac.get(
                "/api/v1/admin/concerts",
                params={"unreviewed_only": True, "search": "검수"},
                headers=_admin_headers(),
            )
    ids = {item["id"] for item in res.json()["items"]}
    assert unreviewed_id in ids
    assert reviewed_id not in ids


# 아티스트 조회 페이지(GET /admin/artists) - 목록 검색 + 별칭/관계 요약 테스트

@pytest.mark.asyncio
async def test_admin_artists_list_search_finds_by_alias():
    name = f"아티스트본명_{uuid.uuid4().hex[:6]}"
    alias = f"별칭_{uuid.uuid4().hex[:6]}"
    async with AsyncSessionLocal() as db:
        canonical = CanonicalArtist(canonical_name=name)
        db.add(canonical)
        await db.flush()
        db.add(ArtistAlias(canonical_artist_id=canonical.id, alias_text=alias, source="musicbrainz"))
        await db.commit()
        canonical_id = str(canonical.id)

    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.get("/api/v1/admin/artists", params={"search": alias}, headers=_admin_headers())
    assert res.status_code == 200
    ids = {item["id"] for item in res.json()["items"]}
    assert canonical_id in ids
    item = next(item for item in res.json()["items"] if item["id"] == canonical_id)
    assert item["alias_count"] == 1


@pytest.mark.asyncio
async def test_admin_artist_detail_shows_aliases_and_own_concerts():
    name = f"상세아티스트_{uuid.uuid4().hex[:6]}"
    alias = f"상세별칭_{uuid.uuid4().hex[:6]}"
    async with AsyncSessionLocal() as db:
        canonical = CanonicalArtist(canonical_name=name)
        db.add(canonical)
        await db.flush()
        db.add(ArtistAlias(canonical_artist_id=canonical.id, alias_text=alias, source="musicbrainz"))
        await db.commit()
        canonical_id = str(canonical.id)

    concert_id = await _create_concert(f"PF_ARTIST_DETAIL_{uuid.uuid4().hex[:6]}", name)

    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.get(f"/api/v1/admin/artists/{canonical_id}", headers=_admin_headers())
    assert res.status_code == 200
    data = res.json()
    assert {a["text"] for a in data["aliases"]} == {alias}
    assert any(c["id"] == concert_id for c in data["concerts"])
    assert data["group_members"] == []
    assert data["member_of"] == []


# 멤버 상세에서 소속 그룹 + 그룹명으로 나온 공연까지 같이 보이는지 테스트
@pytest.mark.asyncio
async def test_admin_artist_detail_shows_group_membership_and_group_concerts():
    group_name = f"그룹_{uuid.uuid4().hex[:6]}"
    member_name = f"멤버_{uuid.uuid4().hex[:6]}"
    async with AsyncSessionLocal() as db:
        group = CanonicalArtist(canonical_name=group_name)
        member = CanonicalArtist(canonical_name=member_name)
        db.add_all([group, member])
        await db.flush()
        db.add(ArtistGroupMembership(member_canonical_id=member.id, group_canonical_id=group.id))
        await db.commit()
        member_id = str(member.id)
        group_id = str(group.id)

    group_concert_id = await _create_concert(f"PF_ARTIST_GROUPCONCERT_{uuid.uuid4().hex[:6]}", group_name)

    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            member_res = await ac.get(f"/api/v1/admin/artists/{member_id}", headers=_admin_headers())
            group_res = await ac.get(f"/api/v1/admin/artists/{group_id}", headers=_admin_headers())

    assert member_res.json()["member_of"] == [group_name]
    assert any(c["id"] == group_concert_id for c in member_res.json()["group_concerts"])
    assert group_res.json()["group_members"] == [member_name]


@pytest.mark.asyncio
async def test_admin_add_artist_alias():
    name = f"별칭추가대상_{uuid.uuid4().hex[:6]}"
    async with AsyncSessionLocal() as db:
        canonical = CanonicalArtist(canonical_name=name)
        db.add(canonical)
        await db.commit()
        canonical_id = str(canonical.id)

    new_alias = f"새별칭_{uuid.uuid4().hex[:6]}"
    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.post(
                f"/api/v1/admin/artists/{canonical_id}/alias",
                json={"alias_text": new_alias},
                headers=_admin_headers(),
            )
    assert res.status_code == 200
    assert new_alias in {a["text"] for a in res.json()["aliases"]}


# 미출연(어느 공연에도 안 나오는) 아티스트 표시 + 필터 + DB 완전 삭제 테스트

@pytest.mark.asyncio
async def test_admin_artist_unused_flag_and_filter():
    unused_name = f"미출연아티스트_{uuid.uuid4().hex[:6]}"
    used_name = f"등장하는아티스트_{uuid.uuid4().hex[:6]}"
    async with AsyncSessionLocal() as db:
        unused_artist = CanonicalArtist(canonical_name=unused_name)
        used = CanonicalArtist(canonical_name=used_name)
        db.add_all([unused_artist, used])
        await db.commit()
        unused_id, used_id = str(unused_artist.id), str(used.id)

    await _create_concert(f"PF_ARTIST_USED_{uuid.uuid4().hex[:6]}", used_name)

    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res_all = await ac.get(
                "/api/v1/admin/artists", params={"search": "아티스트_"}, headers=_admin_headers()
            )
            res_unused = await ac.get(
                "/api/v1/admin/artists",
                params={"search": "아티스트_", "unused_only": True},
                headers=_admin_headers(),
            )

    items_all = {item["id"]: item for item in res_all.json()["items"]}
    assert items_all[unused_id]["is_unused"] is True
    assert items_all[used_id]["is_unused"] is False

    unused_ids = {item["id"] for item in res_unused.json()["items"]}
    assert unused_id in unused_ids
    assert used_id not in unused_ids


@pytest.mark.asyncio
async def test_admin_delete_unused_artist():
    name = f"삭제대상_{uuid.uuid4().hex[:6]}"
    async with AsyncSessionLocal() as db:
        canonical = CanonicalArtist(canonical_name=name)
        db.add(canonical)
        await db.flush()
        db.add(ArtistAlias(canonical_artist_id=canonical.id, alias_text=f"삭제별칭_{uuid.uuid4().hex[:6]}", source="admin"))
        await db.commit()
        canonical_id = str(canonical.id)

    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.delete(f"/api/v1/admin/artists/{canonical_id}", headers=_admin_headers())
    assert res.status_code == 200
    assert res.json()["deleted"] is True

    async with AsyncSessionLocal() as db:
        assert await db.get(CanonicalArtist, uuid.UUID(canonical_id)) is None
        alias_rows = (
            await db.execute(select(ArtistAlias).where(ArtistAlias.canonical_artist_id == uuid.UUID(canonical_id)))
        ).scalars().all()
        assert alias_rows == []  # cascade로 같이 삭제됨


@pytest.mark.asyncio
async def test_admin_delete_artist_rejected_when_still_in_use():
    name = f"사용중_{uuid.uuid4().hex[:6]}"
    await _create_concert(f"PF_ARTIST_INUSE_{uuid.uuid4().hex[:6]}", name)

    # KOPIS로만 채워진 콘서트는 자동으로 canonical이 안 생기므로(정규화 배치가 지나가야 함)
    # 테스트에서 직접 생성 - 콘서트 쪽 표기(name)와 겹치는 canonical이 있는 상황을 재현
    async with AsyncSessionLocal() as db:
        canonical = CanonicalArtist(canonical_name=name)
        db.add(canonical)
        await db.commit()
        canonical_id = str(canonical.id)

    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.delete(f"/api/v1/admin/artists/{canonical_id}", headers=_admin_headers())
    assert res.status_code == 400

    async with AsyncSessionLocal() as db:
        assert await db.get(CanonicalArtist, uuid.UUID(canonical_id)) is not None


# 삭제 대상이 그룹-멤버 관계에 얽혀 있어도(자신이 그룹이거나 멤버여도) 관계까지 같이 정리되고
# 에러 없이 삭제되는지 테스트
@pytest.mark.asyncio
async def test_admin_delete_artist_cleans_up_group_membership():
    group_name = f"삭제될그룹_{uuid.uuid4().hex[:6]}"
    member_name = f"삭제될그룹멤버_{uuid.uuid4().hex[:6]}"
    async with AsyncSessionLocal() as db:
        group = CanonicalArtist(canonical_name=group_name)
        member = CanonicalArtist(canonical_name=member_name)
        db.add_all([group, member])
        await db.flush()
        db.add(ArtistGroupMembership(member_canonical_id=member.id, group_canonical_id=group.id))
        await db.commit()
        member_id = str(member.id)

    with _admin_settings():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.delete(f"/api/v1/admin/artists/{member_id}", headers=_admin_headers())
    assert res.status_code == 200

    async with AsyncSessionLocal() as db:
        remaining = (
            await db.execute(
                select(ArtistGroupMembership).where(ArtistGroupMembership.member_canonical_id == uuid.UUID(member_id))
            )
        ).scalars().all()
        assert remaining == []
