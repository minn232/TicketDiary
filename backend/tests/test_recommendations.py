import uuid
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from httpx import AsyncClient, ASGITransport

from app.core.database import AsyncSessionLocal
from app.main import app
from app.models.artist_similarity import ArtistSimilarity
from app.models.ticket import Ticket
from conftest import _get_token, kopis_mock


# 헬퍼

# KOPIS 공연 상세 XML 생성 (아티스트 지정 가능)
def _make_detail_xml(kopis_id: str, artist: str) -> bytes:
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>'
        f"<dbs><db>"
        f"<mt20id>{kopis_id}</mt20id>"
        f"<prfnm>{kopis_id} 공연</prfnm>"
        f"<prfpdfrom>2030.06.01</prfpdfrom>"
        f"<prfpdto>2030.06.30</prfpdto>"
        f"<fcltynm>테스트공연장</fcltynm>"
        f'<poster>https://example.com/poster.jpg</poster>'
        f"<genrenm>대중음악</genrenm>"
        f"<prfcast>{artist}</prfcast>"
        f"<pcseguidance>R석 110,000원</pcseguidance>"
        f"<sty>공연 소개</sty>"
        f"</db></dbs>"
    ).encode("utf-8")


# KOPIS mock으로 공연 상세 조회 후 concert_id 반환 (해당 아티스트로 DB에 upsert됨)
async def _create_concert(kopis_id: str, artist: str, token: str) -> str:
    with kopis_mock(_make_detail_xml(kopis_id, artist)):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.get(
                f"/api/v1/concerts/{kopis_id}",
                headers={"Authorization": f"Bearer {token}"},
            )
    assert res.status_code == 200
    return res.json()["id"]


# 토큰으로 현재 유저 id 조회
async def _get_user_id(token: str) -> str:
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert res.status_code == 200
    return res.json()["id"]


# ArtistSimilarity 캐시 직접 삽입 (Last.fm 응답을 미리 캐싱해둔 상태를 시뮬레이션)
async def _insert_similarity(artist_name: str, similar_artist_name: str, match_score: float) -> None:
    async with AsyncSessionLocal() as db:
        db.add(ArtistSimilarity(artist_name=artist_name, similar_artist_name=similar_artist_name, match_score=match_score))
        await db.commit()


# 아티스트 팔로우 설정
async def _follow_artist(token: str, artist_name: str) -> None:
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": artist_name}]},
            headers={"Authorization": f"Bearer {token}"},
        )
    assert res.status_code == 200


# lastfm.fetch_similar_artists 테스트

@pytest.mark.asyncio
async def test_fetch_similar_artists_success():
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = {
        "similarartists": {
            "artist": [
                {"name": "아티스트B", "match": "0.9"},
                {"name": "아티스트C", "match": "0.5"},
            ]
        }
    }
    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = AsyncMock(return_value=mock_response)

    with patch("app.services.lastfm.settings.LASTFM_API_KEY", "test-key"), \
         patch("app.services.lastfm.httpx.AsyncClient", return_value=mock_client):
        from app.services.lastfm import fetch_similar_artists

        result = await fetch_similar_artists("아티스트A")

    assert result == [("아티스트B", 0.9), ("아티스트C", 0.5)]


@pytest.mark.asyncio
async def test_fetch_similar_artists_no_api_key_returns_empty():
    with patch("app.services.lastfm.settings.LASTFM_API_KEY", ""):
        from app.services.lastfm import fetch_similar_artists

        result = await fetch_similar_artists("아티스트A")

    assert result == []


# 200 응답이지만 몸체가 JSON이 아니면(순간 오류 등) 예외 없이 빈 리스트를 반환하는지 테스트
@pytest.mark.asyncio
async def test_fetch_similar_artists_malformed_json_returns_empty():
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.side_effect = ValueError("invalid json")
    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.get = AsyncMock(return_value=mock_response)

    with patch("app.services.lastfm.settings.LASTFM_API_KEY", "test-key"), \
         patch("app.services.lastfm.httpx.AsyncClient", return_value=mock_client):
        from app.services.lastfm import fetch_similar_artists

        result = await fetch_similar_artists("아티스트A")

    assert result == []


# sync_artist_similarities 테스트

@pytest.mark.asyncio
async def test_sync_artist_similarities_skips_already_cached():
    token = await _get_token()
    kopis_a = f"PF_LFM_A_{uuid.uuid4().hex[:6]}"
    kopis_b = f"PF_LFM_B_{uuid.uuid4().hex[:6]}"
    artist_a = f"신규아티스트_{uuid.uuid4().hex[:6]}"
    artist_b = f"기존아티스트_{uuid.uuid4().hex[:6]}"

    await _create_concert(kopis_a, artist_a, token)
    await _create_concert(kopis_b, artist_b, token)
    # artist_b는 이미 캐싱된 것으로 미리 세팅
    await _insert_similarity(artist_b, "무관아티스트", 0.1)

    mock_fetch = AsyncMock(return_value=[("유사아티스트", 0.7)])
    with patch("app.services.lastfm.fetch_similar_artists", mock_fetch):
        from app.services.lastfm import sync_artist_similarities

        await sync_artist_similarities()

    # artist_a(신규)만 호출됐어야 함 - artist_b는 이미 캐싱되어 있어 스킵
    called_names = {call.args[0] for call in mock_fetch.await_args_list}
    assert artist_a in called_names
    assert artist_b not in called_names


# 캐싱 대상 아티스트 중 하나에서 예기치 못한 오류가 나도, 그 뒤 아티스트는 계속 처리되는지 테스트
# (알파벳/가나다순 정렬이라 한 아티스트가 매번 같은 자리에서 막히면 그 뒤가 영구히 밀리는 버그 회귀 방지)
@pytest.mark.asyncio
async def test_sync_artist_similarities_continues_after_one_artist_fails():
    token = await _get_token()
    kopis_broken = f"PF_LFM_BROKEN_{uuid.uuid4().hex[:6]}"
    kopis_ok = f"PF_LFM_OK_{uuid.uuid4().hex[:6]}"
    artist_broken = f"가장먼저오는아티스트_{uuid.uuid4().hex[:6]}"
    artist_ok = f"나중에오는아티스트_{uuid.uuid4().hex[:6]}"

    await _create_concert(kopis_broken, artist_broken, token)
    await _create_concert(kopis_ok, artist_ok, token)

    async def _mock_fetch(artist_name: str, limit: int = 30):
        if artist_name == artist_broken:
            raise RuntimeError("예기치 못한 오류")
        return [("유사아티스트", 0.7)]

    with patch("app.services.lastfm.fetch_similar_artists", AsyncMock(side_effect=_mock_fetch)):
        from app.services.lastfm import sync_artist_similarities

        await sync_artist_similarities()

    async with AsyncSessionLocal() as db:
        from sqlalchemy import select
        result = await db.execute(
            select(ArtistSimilarity).where(ArtistSimilarity.artist_name == artist_ok)
        )
        assert result.scalars().first() is not None


# GET /recommendations/artists 테스트

@pytest.mark.asyncio
async def test_recommendations_no_auth_401():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/recommendations/artists")
    assert res.status_code == 401


@pytest.mark.asyncio
async def test_recommendations_empty_without_follows_or_tickets():
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/recommendations/artists", headers={"Authorization": f"Bearer {token}"})

    assert res.status_code == 200
    assert res.json()["recommendations"] == []


@pytest.mark.asyncio
async def test_recommendations_basic_ranking_and_exclusions():
    token = await _get_token()
    seed = f"팔로우아티스트_{uuid.uuid4().hex[:6]}"
    high = f"유사도높음_{uuid.uuid4().hex[:6]}"
    low = f"유사도낮음_{uuid.uuid4().hex[:6]}"
    no_concert = f"공연없음_{uuid.uuid4().hex[:6]}"

    # seed, high, low는 실제 공연이 있고, no_concert는 Last.fm엔 나오지만 이 앱에 공연이 없음
    await _create_concert(f"PF_REC_SEED_{uuid.uuid4().hex[:6]}", seed, token)
    await _create_concert(f"PF_REC_HIGH_{uuid.uuid4().hex[:6]}", high, token)
    await _create_concert(f"PF_REC_LOW_{uuid.uuid4().hex[:6]}", low, token)

    await _follow_artist(token, seed)
    await _insert_similarity(seed, high, 0.9)
    await _insert_similarity(seed, low, 0.3)
    await _insert_similarity(seed, no_concert, 0.99)
    await _insert_similarity(seed, seed, 0.5)  # 자기 자신은 제외돼야 함

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/recommendations/artists", headers={"Authorization": f"Bearer {token}"})

    assert res.status_code == 200
    recs = res.json()["recommendations"]
    names = [r["artist_name"] for r in recs]

    assert seed not in names  # 이미 팔로우 중인 아티스트는 제외
    assert no_concert not in names  # 이 앱에 공연이 없는 아티스트는 제외
    assert names.index(high) < names.index(low)  # 점수 높은 순 정렬


# 서로 다른 시드 아티스트가 같은 실제 아티스트를 다른 대소문자로 참조해도(Last.fm 캐시가 시드별로
# 독립적으로 채워질 때 생길 수 있음), 추천 목록엔 중복 없이 점수가 합산되어 한 번만 뜨는지 테스트
@pytest.mark.asyncio
async def test_recommendations_merges_case_insensitive_duplicate_names():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}
    seed_a = f"팔로우A_{uuid.uuid4().hex[:6]}"
    seed_b = f"팔로우B_{uuid.uuid4().hex[:6]}"
    target = f"Target_{uuid.uuid4().hex[:6]}"

    await _create_concert(f"PF_REC_MERGE_A_{uuid.uuid4().hex[:6]}", seed_a, token)
    await _create_concert(f"PF_REC_MERGE_B_{uuid.uuid4().hex[:6]}", seed_b, token)
    await _create_concert(f"PF_REC_MERGE_T_{uuid.uuid4().hex[:6]}", target, token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        follow_res = await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": seed_a}, {"artist_name": seed_b}]},
            headers=headers,
        )
    assert follow_res.status_code == 200

    await _insert_similarity(seed_a, target.upper(), 0.6)
    await _insert_similarity(seed_b, target.lower(), 0.4)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/recommendations/artists", headers=headers)

    recs = res.json()["recommendations"]
    matching = [r for r in recs if r["artist_name"].lower() == target.lower()]
    assert len(matching) == 1
    assert matching[0]["score"] == pytest.approx(1.0)


@pytest.mark.asyncio
async def test_recommendations_limit_param():
    token = await _get_token()
    seed = f"리밋팔로우_{uuid.uuid4().hex[:6]}"
    await _create_concert(f"PF_REC_LIMSEED_{uuid.uuid4().hex[:6]}", seed, token)
    await _follow_artist(token, seed)

    for i in range(3):
        name = f"리밋추천_{i}_{uuid.uuid4().hex[:6]}"
        await _create_concert(f"PF_REC_LIM_{i}_{uuid.uuid4().hex[:6]}", name, token)
        await _insert_similarity(seed, name, 1.0 - i * 0.1)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get(
            "/api/v1/recommendations/artists",
            params={"limit": 2},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert res.status_code == 200
    assert len(res.json()["recommendations"]) == 2


@pytest.mark.asyncio
async def test_recommendations_cold_start_falls_back_to_ticket_history():
    token = await _get_token()
    user_id = await _get_user_id(token)
    watched = f"관람아티스트_{uuid.uuid4().hex[:6]}"
    similar = f"관람유사_{uuid.uuid4().hex[:6]}"

    watched_concert_id = await _create_concert(f"PF_REC_WATCHED_{uuid.uuid4().hex[:6]}", watched, token)
    await _create_concert(f"PF_REC_SIMILAR_{uuid.uuid4().hex[:6]}", similar, token)
    await _insert_similarity(watched, similar, 0.8)

    # 팔로우 없이 티켓 등록 이력만 있는 상태를 시뮬레이션 (직접 DB 삽입)
    async with AsyncSessionLocal() as db:
        db.add(Ticket(user_id=uuid.UUID(user_id), concert_id=uuid.UUID(watched_concert_id)))
        await db.commit()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/recommendations/artists", headers={"Authorization": f"Bearer {token}"})

    assert res.status_code == 200
    names = [r["artist_name"] for r in res.json()["recommendations"]]
    assert similar in names
