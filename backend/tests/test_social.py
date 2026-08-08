import uuid
from unittest.mock import AsyncMock, patch

import pytest
from httpx import AsyncClient, ASGITransport

from app.main import app
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


# KOPIS mock으로 공연 상세 조회 후 concert_id 반환 (kopis_id를 직접 지정)
async def _fetch_concert(kopis_id: str, artist: str, token: str) -> str:
    xml = _make_detail_xml(kopis_id, artist)
    with kopis_mock(xml):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            res = await ac.get(
                f"/api/v1/concerts/{kopis_id}",
                headers={"Authorization": f"Bearer {token}"},
            )
    assert res.status_code == 200
    return res.json()["id"]


# 선호 아티스트 조회 테스트

# 초기 조회 시 빈 목록 반환 테스트
@pytest.mark.asyncio
async def test_get_artist_follow_empty():
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/social/artists", headers={"Authorization": f"Bearer {token}"})

    assert res.status_code == 200
    assert res.json()["artists"] == []


# 미인증 요청 401 테스트
@pytest.mark.asyncio
async def test_get_artist_follow_no_auth_401():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/social/artists")

    assert res.status_code == 401


# 선호 아티스트 수정 테스트

# 아티스트 목록 수정 성공 테스트
@pytest.mark.asyncio
async def test_update_artist_follow_success():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": "아이유"}, {"artist_name": "BTS", "kopis_artist_id": "KA001"}]},
            headers=headers,
        )

    assert res.status_code == 200
    data = res.json()
    assert len(data["artists"]) == 2
    names = [a["artist_name"] for a in data["artists"]]
    assert "아이유" in names
    assert "BTS" in names


# 수정 후 재조회 시 반영 확인 테스트
@pytest.mark.asyncio
async def test_update_artist_follow_persisted():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": "아이유"}]},
            headers=headers,
        )
        res = await ac.get("/api/v1/social/artists", headers=headers)

    assert res.status_code == 200
    assert res.json()["artists"][0]["artist_name"] == "아이유"


# 목록 전체 교체 확인 테스트
@pytest.mark.asyncio
async def test_update_artist_follow_replaces_all():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": "아이유"}, {"artist_name": "BTS"}]},
            headers=headers,
        )
        res = await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": "뉴진스"}]},
            headers=headers,
        )

    assert res.status_code == 200
    data = res.json()
    assert len(data["artists"]) == 1
    assert data["artists"][0]["artist_name"] == "뉴진스"


# 빈 목록으로 전체 초기화 테스트
@pytest.mark.asyncio
async def test_update_artist_follow_clear():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": "아이유"}]},
            headers=headers,
        )
        res = await ac.patch("/api/v1/social/artists", json={"artists": []}, headers=headers)

    assert res.status_code == 200
    assert res.json()["artists"] == []


# 찜 공연 조회 테스트

# 초기 조회 시 빈 목록 반환 테스트
@pytest.mark.asyncio
async def test_get_concert_follow_empty():
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/social/concerts", headers={"Authorization": f"Bearer {token}"})

    assert res.status_code == 200
    assert res.json()["concerts"] == []


# 미인증 요청 401 테스트
@pytest.mark.asyncio
async def test_get_concert_follow_no_auth_401():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/social/concerts")

    assert res.status_code == 401


# 찜 공연 수정 테스트

# 찜 공연 수정 성공 테스트
@pytest.mark.asyncio
async def test_update_concert_follow_success():
    token = await _get_token()
    kopis_id = f"PF_CFOLLOW_{uuid.uuid4().hex[:8]}"
    concert_id = await _fetch_concert(kopis_id, "테스트아티스트", token)
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.patch(
            "/api/v1/social/concerts",
            json={"concerts": [{"concert_id": concert_id}]},
            headers=headers,
        )

    assert res.status_code == 200
    data = res.json()
    assert len(data["concerts"]) == 1
    assert data["concerts"][0]["concert_id"] == concert_id


# 찜 등록 시 티켓팅 오픈일을 미리 알아낼 수 있도록 백그라운드로 크롤링이 트리거되는지 테스트
# (아직 아무도 티켓을 등록 안 한 공연이라도 KOPIS 상세조회로 이미 채워진 ticketing_links로 시도됨)
@pytest.mark.asyncio
async def test_update_concert_follow_triggers_crawl():
    token = await _get_token()
    kopis_id = f"PF_CFOLLOW_CRAWL_{uuid.uuid4().hex[:8]}"
    concert_id = await _fetch_concert(kopis_id, "테스트아티스트", token)
    headers = {"Authorization": f"Bearer {token}"}

    with patch("app.api.v1.endpoints.social.crawl_and_save", new=AsyncMock()) as mock_crawl:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.patch(
                "/api/v1/social/concerts",
                json={"concerts": [{"concert_id": concert_id}]},
                headers=headers,
            )

    mock_crawl.assert_awaited_once()
    assert str(mock_crawl.call_args.args[0]) == concert_id


# 수정 후 재조회 시 반영 확인 테스트
@pytest.mark.asyncio
async def test_update_concert_follow_persisted():
    token = await _get_token()
    kopis_id = f"PF_CFOLLOW_{uuid.uuid4().hex[:8]}"
    concert_id = await _fetch_concert(kopis_id, "테스트아티스트", token)
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/concerts",
            json={"concerts": [{"concert_id": concert_id}]},
            headers=headers,
        )
        res = await ac.get("/api/v1/social/concerts", headers=headers)

    assert res.status_code == 200
    assert res.json()["concerts"][0]["concert_id"] == concert_id


# 목록 전체 교체 확인 테스트
@pytest.mark.asyncio
async def test_update_concert_follow_replaces_all():
    token = await _get_token()
    concert_id_1 = await _fetch_concert(f"PF_CFREPL_{uuid.uuid4().hex[:8]}", "테스트아티스트", token)
    concert_id_2 = await _fetch_concert(f"PF_CFREPL_{uuid.uuid4().hex[:8]}", "테스트아티스트", token)
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/concerts",
            json={"concerts": [{"concert_id": concert_id_1}, {"concert_id": concert_id_2}]},
            headers=headers,
        )
        res = await ac.patch(
            "/api/v1/social/concerts",
            json={"concerts": [{"concert_id": concert_id_1}]},
            headers=headers,
        )

    assert res.status_code == 200
    assert len(res.json()["concerts"]) == 1
    assert res.json()["concerts"][0]["concert_id"] == concert_id_1


# 뉴스피드 조회 테스트

# 초기 뉴스피드 빈 목록 테스트
@pytest.mark.asyncio
async def test_get_news_feed_empty():
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/social/feed", headers={"Authorization": f"Bearer {token}"})

    assert res.status_code == 200
    assert res.json() == []


# 팔로우 아티스트의 공연 상세 조회 시 뉴스피드 자동 생성 테스트
@pytest.mark.asyncio
async def test_news_feed_created_on_artist_concert_detail():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}
    artist_name = f"뉴스피드아티스트_{uuid.uuid4().hex}"
    kopis_id = f"PF_FEED_{uuid.uuid4().hex[:8]}"

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": artist_name}]},
            headers=headers,
        )

    await _fetch_concert(kopis_id, artist_name, token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/social/feed", headers=headers)

    assert res.status_code == 200
    feed = res.json()
    assert len(feed) == 1
    assert feed[0]["artist_name"] == artist_name
    assert feed[0]["is_read"] is False
    assert feed[0]["concert"] is not None


# limit/offset 파라미터로 페이지네이션되는지, 생략 시 기본값(최대 200건)이 적용되는지 테스트
@pytest.mark.asyncio
async def test_news_feed_pagination():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}
    artist_name = f"피드페이지아티스트_{uuid.uuid4().hex}"

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": artist_name}]},
            headers=headers,
        )

    for i in range(5):
        await _fetch_concert(f"PF_FEEDPAGE_{i}_{uuid.uuid4().hex[:8]}", artist_name, token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        default_res = await ac.get("/api/v1/social/feed", headers=headers)
        limited_res = await ac.get("/api/v1/social/feed", params={"limit": 2}, headers=headers)
        offset_res = await ac.get("/api/v1/social/feed", params={"limit": 2, "offset": 2}, headers=headers)

    assert len(default_res.json()) == 5
    assert len(limited_res.json()) == 2
    assert len(offset_res.json()) == 2
    first_page_ids = {f["id"] for f in limited_res.json()}
    second_page_ids = {f["id"] for f in offset_res.json()}
    assert first_page_ids.isdisjoint(second_page_ids)


# 미팔로우 아티스트 공연 상세 조회 시 뉴스피드 미생성 테스트
@pytest.mark.asyncio
async def test_news_feed_not_created_for_non_followed_artist():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": "팔로우아티스트"}]},
            headers=headers,
        )

    await _fetch_concert(f"PF_FEED_{uuid.uuid4().hex[:8]}", "미팔로우아티스트X", token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/social/feed", headers=headers)

    assert res.status_code == 200
    assert res.json() == []


# 동일 공연 중복 뉴스피드 미생성 테스트
@pytest.mark.asyncio
async def test_news_feed_no_duplicate():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}
    artist_name = f"뉴스피드아티스트_{uuid.uuid4().hex}"
    kopis_id = f"PF_FEED_{uuid.uuid4().hex[:8]}"
    xml = _make_detail_xml(kopis_id, artist_name)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": artist_name}]},
            headers=headers,
        )

    # 동일 공연 두 번 조회 (두 번째는 DB 캐시 반환 -> 뉴스피드 미생성)
    with kopis_mock(xml):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            await ac.get(f"/api/v1/concerts/{kopis_id}", headers=headers)
            await ac.get(f"/api/v1/concerts/{kopis_id}", headers=headers)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/social/feed", headers=headers)

    assert res.status_code == 200
    assert len(res.json()) == 1


# 이미 존재하는 공연의 아티스트를 나중에 팔로우하면 즉시 뉴스피드 생성 테스트
@pytest.mark.asyncio
async def test_news_feed_created_immediately_on_follow_for_existing_concert():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}
    artist_name = f"뒤늦은팔로우아티스트_{uuid.uuid4().hex}"
    kopis_id = f"PF_FEED_{uuid.uuid4().hex[:8]}"

    # 공연을 먼저 생성 (아직 팔로우 안 한 상태)
    await _fetch_concert(kopis_id, artist_name, token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/social/feed", headers=headers)
    assert res.json() == []

    # 이후에 해당 아티스트를 팔로우 -> 배치를 기다리지 않고 바로 반영돼야 함
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": artist_name}]},
            headers=headers,
        )

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/social/feed", headers=headers)

    assert res.status_code == 200
    feed = res.json()
    assert len(feed) == 1
    assert feed[0]["artist_name"] == artist_name


# 이미 팔로우 중인 아티스트를 재저장(중복 포함)해도 뉴스피드 중복 생성 안 됨 테스트
@pytest.mark.asyncio
async def test_news_feed_no_duplicate_on_refollow_same_artist():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}
    artist_name = f"재팔로우아티스트_{uuid.uuid4().hex}"
    kopis_id = f"PF_FEED_{uuid.uuid4().hex[:8]}"

    await _fetch_concert(kopis_id, artist_name, token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": artist_name}]},
            headers=headers,
        )
        # 동일 아티스트로 다시 PATCH (전체 교체지만 내용은 그대로)
        await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": artist_name}]},
            headers=headers,
        )

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/social/feed", headers=headers)

    assert res.status_code == 200
    assert len(res.json()) == 1


# 미인증 요청 401 테스트
@pytest.mark.asyncio
async def test_get_news_feed_no_auth_401():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.get("/api/v1/social/feed")

    assert res.status_code == 401


# 뉴스피드 읽음 처리 테스트

# 읽음 처리 성공 테스트
@pytest.mark.asyncio
async def test_mark_feed_read_success():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}
    artist_name = f"뉴스피드아티스트_{uuid.uuid4().hex}"
    kopis_id = f"PF_FEED_{uuid.uuid4().hex[:8]}"

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": artist_name}]},
            headers=headers,
        )

    await _fetch_concert(kopis_id, artist_name, token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        feed_res = await ac.get("/api/v1/social/feed", headers=headers)
        feed_id = feed_res.json()[0]["id"]

        res = await ac.patch(f"/api/v1/social/feed/{feed_id}/read", headers=headers)

    assert res.status_code == 200
    assert res.json()["is_read"] is True
    assert res.json()["id"] == feed_id


# 읽음 처리 후 재조회 시 is_read=True 유지 테스트
@pytest.mark.asyncio
async def test_mark_feed_read_persisted():
    token = await _get_token()
    headers = {"Authorization": f"Bearer {token}"}
    artist_name = f"뉴스피드아티스트_{uuid.uuid4().hex}"
    kopis_id = f"PF_FEED_{uuid.uuid4().hex[:8]}"

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": artist_name}]},
            headers=headers,
        )

    await _fetch_concert(kopis_id, artist_name, token)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        feed_res = await ac.get("/api/v1/social/feed", headers=headers)
        feed_id = feed_res.json()[0]["id"]
        await ac.patch(f"/api/v1/social/feed/{feed_id}/read", headers=headers)

        res = await ac.get("/api/v1/social/feed", headers=headers)

    feed = next(f for f in res.json() if f["id"] == feed_id)
    assert feed["is_read"] is True


# 존재하지 않는 뉴스피드 읽음 처리 404 테스트
@pytest.mark.asyncio
async def test_mark_feed_read_not_found_404():
    token = await _get_token()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        res = await ac.patch(
            f"/api/v1/social/feed/{uuid.uuid4()}/read",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert res.status_code == 404


# 다른 유저의 뉴스피드 읽음 처리 404 테스트
@pytest.mark.asyncio
async def test_mark_feed_read_other_user_404():
    token_a = await _get_token()
    token_b = await _get_token()
    artist_name = f"뉴스피드아티스트_{uuid.uuid4().hex}"
    kopis_id = f"PF_FEED_{uuid.uuid4().hex[:8]}"

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        await ac.patch(
            "/api/v1/social/artists",
            json={"artists": [{"artist_name": artist_name}]},
            headers={"Authorization": f"Bearer {token_a}"},
        )

    await _fetch_concert(kopis_id, artist_name, token_a)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        feed_res = await ac.get(
            "/api/v1/social/feed",
            headers={"Authorization": f"Bearer {token_a}"},
        )
        feed_id = feed_res.json()[0]["id"]

        res = await ac.patch(
            f"/api/v1/social/feed/{feed_id}/read",
            headers={"Authorization": f"Bearer {token_b}"},
        )

    assert res.status_code == 404
