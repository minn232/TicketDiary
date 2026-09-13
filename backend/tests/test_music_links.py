from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from httpx import AsyncClient, ASGITransport

from app.core.config import settings
from app.main import app
from conftest import _get_token


def _mock_response(json_data: dict, status_code: int = 200) -> MagicMock:
    resp = MagicMock()
    resp.status_code = status_code
    resp.raise_for_status = MagicMock()
    resp.json = MagicMock(return_value=json_data)
    return resp


def _music_resolve_client_mock(**responses):
    # responses: post=..., get=... (AsyncMock 또는 단일 응답, 여러 번 호출되면 side_effect로 전달)
    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    if "post" in responses:
        mock_client.post = AsyncMock(return_value=responses["post"])
    if "get" in responses:
        get_value = responses["get"]
        if isinstance(get_value, list):
            mock_client.get = AsyncMock(side_effect=get_value)
        else:
            mock_client.get = AsyncMock(return_value=get_value)
    return patch("app.services.music_resolve.httpx.AsyncClient", return_value=mock_client)


@pytest.fixture(autouse=True)
def _reset_spotify_token_cache():
    # 모듈 전역 토큰 캐시가 테스트 간에 새지 않도록 매 테스트 전에 초기화
    import app.services.music_resolve as music_resolve

    music_resolve._spotify_token = None
    music_resolve._spotify_token_expires_at = 0.0
    yield
    music_resolve._spotify_token = None
    music_resolve._spotify_token_expires_at = 0.0


# 알 수 없는 service면 그냥 url=None(에러 아님)
@pytest.mark.asyncio
async def test_resolve_unknown_service_returns_null():
    token = await _get_token()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.get(
            "/api/v1/music-links/resolve",
            params={"service": "melon", "song": "곡", "artist": "아티스트"},
            headers={"Authorization": f"Bearer {token}"},
        )
    assert response.status_code == 200
    assert response.json() == {"url": None}


# 스포티파이 client_id/secret 미설정이면 토큰 발급 자체를 시도하지 않고 null
@pytest.mark.asyncio
async def test_resolve_spotify_without_credentials_returns_null():
    token = await _get_token()
    with patch.object(settings, "SPOTIFY_CLIENT_ID", ""), patch.object(settings, "SPOTIFY_CLIENT_SECRET", ""):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                "/api/v1/music-links/resolve",
                params={"service": "spotify", "song": "노래", "artist": "가수"},
                headers={"Authorization": f"Bearer {token}"},
            )
    assert response.status_code == 200
    assert response.json() == {"url": None}


# 스포티파이 정상 매칭 - 토큰 발급 + 검색 둘 다 성공하면 트랙 URL 반환
@pytest.mark.asyncio
async def test_resolve_spotify_success():
    token = await _get_token()
    token_resp = _mock_response({"access_token": "fake-token", "expires_in": 3600})
    search_resp = _mock_response(
        {"tracks": {"items": [{"external_urls": {"spotify": "https://open.spotify.com/track/abc123"}}]}}
    )
    with patch.object(settings, "SPOTIFY_CLIENT_ID", "id"), patch.object(settings, "SPOTIFY_CLIENT_SECRET", "secret"):
        with _music_resolve_client_mock(post=token_resp, get=search_resp):
            async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
                response = await ac.get(
                    "/api/v1/music-links/resolve",
                    params={"service": "spotify", "song": "노래", "artist": "가수"},
                    headers={"Authorization": f"Bearer {token}"},
                )
    assert response.status_code == 200
    assert response.json() == {"url": "https://open.spotify.com/track/abc123"}


# 스포티파이 매칭 결과 없음(비공식/미발매곡 등) - null 폴백
@pytest.mark.asyncio
async def test_resolve_spotify_no_match_returns_null():
    token = await _get_token()
    token_resp = _mock_response({"access_token": "fake-token", "expires_in": 3600})
    search_resp = _mock_response({"tracks": {"items": []}})
    with patch.object(settings, "SPOTIFY_CLIENT_ID", "id"), patch.object(settings, "SPOTIFY_CLIENT_SECRET", "secret"):
        with _music_resolve_client_mock(post=token_resp, get=search_resp):
            async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
                response = await ac.get(
                    "/api/v1/music-links/resolve",
                    params={"service": "spotify", "song": "커버곡", "artist": "가수"},
                    headers={"Authorization": f"Bearer {token}"},
                )
    assert response.json() == {"url": None}


# 유튜브 - "Provided to YouTube by" 문구 있는 영상만 원탭 직결
@pytest.mark.asyncio
async def test_resolve_youtube_official_audio_success():
    token = await _get_token()
    search_resp = _mock_response({"items": [{"id": {"videoId": "vid1"}}, {"id": {"videoId": "vid2"}}]})
    detail_resp = _mock_response(
        {
            "items": [
                {"id": "vid1", "snippet": {"description": "그냥 팬캠 영상입니다"}},
                {"id": "vid2", "snippet": {"description": "Provided to YouTube by Some Label"}},
            ]
        }
    )
    with patch.object(settings, "YOUTUBE_API_KEY", "key"):
        with _music_resolve_client_mock(get=[search_resp, detail_resp]):
            async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
                response = await ac.get(
                    "/api/v1/music-links/resolve",
                    params={"service": "youtube", "song": "노래", "artist": "가수"},
                    headers={"Authorization": f"Bearer {token}"},
                )
    assert response.json() == {"url": "https://www.youtube.com/watch?v=vid2"}


# 유튜브뮤직 - 유튜브와 검색 로직은 같고 링크 도메인만 music.youtube.com으로 다르게
@pytest.mark.asyncio
async def test_resolve_youtube_music_uses_music_domain():
    token = await _get_token()
    search_resp = _mock_response({"items": [{"id": {"videoId": "vid1"}}]})
    detail_resp = _mock_response(
        {"items": [{"id": "vid1", "snippet": {"description": "Provided to YouTube by Some Label"}}]}
    )
    with patch.object(settings, "YOUTUBE_API_KEY", "key"):
        with _music_resolve_client_mock(get=[search_resp, detail_resp]):
            async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
                response = await ac.get(
                    "/api/v1/music-links/resolve",
                    params={"service": "youtube_music", "song": "노래", "artist": "가수"},
                    headers={"Authorization": f"Bearer {token}"},
                )
    assert response.json() == {"url": "https://music.youtube.com/watch?v=vid1"}


# 유튜브 - 공식 음원 표시가 하나도 없으면(커버/직캠뿐) null 폴백
@pytest.mark.asyncio
async def test_resolve_youtube_no_official_audio_returns_null():
    token = await _get_token()
    search_resp = _mock_response({"items": [{"id": {"videoId": "vid1"}}]})
    detail_resp = _mock_response(
        {"items": [{"id": "vid1", "snippet": {"description": "팬이 찍은 직캠"}}]}
    )
    with patch.object(settings, "YOUTUBE_API_KEY", "key"):
        with _music_resolve_client_mock(get=[search_resp, detail_resp]):
            async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
                response = await ac.get(
                    "/api/v1/music-links/resolve",
                    params={"service": "youtube", "song": "커버곡", "artist": "가수"},
                    headers={"Authorization": f"Bearer {token}"},
                )
    assert response.json() == {"url": None}


# 애플뮤직 - 유사도 임계치 넘는 결과만 반환
@pytest.mark.asyncio
async def test_resolve_apple_music_success():
    token = await _get_token()
    search_resp = _mock_response(
        {
            "results": [
                {
                    "artistName": "테스트가수",
                    "trackName": "테스트곡",
                    "trackViewUrl": "https://music.apple.com/kr/song/123",
                }
            ]
        }
    )
    with _music_resolve_client_mock(get=search_resp):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                "/api/v1/music-links/resolve",
                params={"service": "apple_music", "song": "테스트곡", "artist": "테스트가수"},
                headers={"Authorization": f"Bearer {token}"},
            )
    assert response.json() == {"url": "https://music.apple.com/kr/song/123"}


# 애플뮤직 - 결과는 있지만 유사도가 낮으면(완전히 다른 곡) null 폴백
@pytest.mark.asyncio
async def test_resolve_apple_music_low_similarity_returns_null():
    token = await _get_token()
    search_resp = _mock_response(
        {
            "results": [
                {
                    "artistName": "전혀 다른 아티스트",
                    "trackName": "전혀 다른 곡",
                    "trackViewUrl": "https://music.apple.com/kr/song/999",
                }
            ]
        }
    )
    with _music_resolve_client_mock(get=search_resp):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                "/api/v1/music-links/resolve",
                params={"service": "apple_music", "song": "테스트곡", "artist": "테스트가수"},
                headers={"Authorization": f"Bearer {token}"},
            )
    assert response.json() == {"url": None}
