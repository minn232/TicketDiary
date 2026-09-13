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


# 유튜브 - 공식 오디오와 공식 뮤비가 둘 다 후보에 있으면(오디오가 검색순위 1등이어도) 뮤비를
# 우선 채택 - 유튜브로 누르는 건 보통 영상을 보고 싶은 거라서.
@pytest.mark.asyncio
async def test_resolve_youtube_prefers_music_video_over_official_audio():
    token = await _get_token()
    search_resp = _mock_response(
        {"items": [{"id": {"videoId": "vid_audio"}}, {"id": {"videoId": "vid_mv"}}]}
    )
    detail_resp = _mock_response(
        {
            "items": [
                # 1등이지만 오디오만
                {
                    "id": "vid_audio",
                    "snippet": {
                        "title": "노래 - 가수",
                        "description": "Provided to YouTube by Some Label",
                    },
                },
                # 2등이지만 진짜 뮤비
                {
                    "id": "vid_mv",
                    "snippet": {"title": "가수 'Song' Official MV", "description": ""},
                },
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
    assert response.json() == {"url": "https://www.youtube.com/watch?v=vid_mv"}


# 유튜브 - 뮤비 후보가 아예 없으면(오디오만 있으면) 오디오라도 씀(위 test와 대조)
@pytest.mark.asyncio
async def test_resolve_youtube_falls_back_to_audio_when_no_mv_candidate():
    token = await _get_token()
    search_resp = _mock_response({"items": [{"id": {"videoId": "vid_audio"}}]})
    detail_resp = _mock_response(
        {
            "items": [
                {
                    "id": "vid_audio",
                    "snippet": {
                        "title": "노래 (Official Audio)",
                        "description": "Provided to YouTube by Some Label",
                    },
                },
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
    assert response.json() == {"url": "https://www.youtube.com/watch?v=vid_audio"}


# 유튜브 - "Provided to YouTube by" 문구가 없어도 제목이 "Official ... MV"면 인정
# (실측: BTS 'Dynamite' Official MV처럼 레이블이 직접 올리는 공식 뮤직비디오는 이 문구가
# 없어서 놓쳤던 버그, backend/tests가 아니라 서버 실배포 후 실제 API 호출로 발견함)
@pytest.mark.asyncio
async def test_resolve_youtube_official_mv_title_success():
    token = await _get_token()
    search_resp = _mock_response({"items": [{"id": {"videoId": "vid1"}}]})
    detail_resp = _mock_response(
        {
            "items": [
                {
                    "id": "vid1",
                    "snippet": {
                        "title": "BTS (방탄소년단) 'Dynamite' Official MV",
                        "description": "Credits:\nDirector: ...",
                    },
                },
            ]
        }
    )
    with patch.object(settings, "YOUTUBE_API_KEY", "key"):
        with _music_resolve_client_mock(get=[search_resp, detail_resp]):
            async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
                response = await ac.get(
                    "/api/v1/music-links/resolve",
                    params={"service": "youtube", "song": "Dynamite", "artist": "BTS"},
                    headers={"Authorization": f"Bearer {token}"},
                )
    assert response.json() == {"url": "https://www.youtube.com/watch?v=vid1"}


# 유튜브 - "official" 단어 없이 "곡명 / 아티스트：MUSIC VIDEO"만 있어도, 채널명이 그
# 아티스트 본인이면 공식 뮤비로 인정 (실측: 일본 아티스트 Vaundy 본인 채널 업로드 컨벤션)
@pytest.mark.asyncio
async def test_resolve_youtube_artist_channel_music_video_without_official_word():
    token = await _get_token()
    search_resp = _mock_response({"items": [{"id": {"videoId": "vid1"}}]})
    detail_resp = _mock_response(
        {
            "items": [
                {
                    "id": "vid1",
                    "snippet": {
                        "title": "CHAINSAW BLOOD / Vaundy：MUSIC VIDEO",
                        "channelTitle": "Vaundy",
                        "description": "助けてチェンソーマン",
                    },
                },
            ]
        }
    )
    with patch.object(settings, "YOUTUBE_API_KEY", "key"):
        with _music_resolve_client_mock(get=[search_resp, detail_resp]):
            async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
                response = await ac.get(
                    "/api/v1/music-links/resolve",
                    params={"service": "youtube", "song": "CHAINSAW BLOOD", "artist": "Vaundy"},
                    headers={"Authorization": f"Bearer {token}"},
                )
    assert response.json() == {"url": "https://www.youtube.com/watch?v=vid1"}


# 유튜브 - "MUSIC VIDEO" 표시가 있어도 채널명이 아티스트 본인이 아니면(팬 채널 등) 인정 안 함
@pytest.mark.asyncio
async def test_resolve_youtube_music_video_title_wrong_channel_returns_null():
    token = await _get_token()
    search_resp = _mock_response({"items": [{"id": {"videoId": "vid1"}}]})
    detail_resp = _mock_response(
        {
            "items": [
                {
                    "id": "vid1",
                    "snippet": {
                        "title": "CHAINSAW BLOOD / Vaundy：MUSIC VIDEO",
                        "channelTitle": "무관한 팬 채널",
                        "description": "",
                    },
                },
            ]
        }
    )
    with patch.object(settings, "YOUTUBE_API_KEY", "key"):
        with _music_resolve_client_mock(get=[search_resp, detail_resp]):
            async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
                response = await ac.get(
                    "/api/v1/music-links/resolve",
                    params={"service": "youtube", "song": "CHAINSAW BLOOD", "artist": "Vaundy"},
                    headers={"Authorization": f"Bearer {token}"},
                )
    assert response.json() == {"url": None}


# 유튜브 - 채널이 아티스트 본인이면 "official"/"mv" 표시가 아예 없어도 인정 (실측: 일본
# 아티스트 Kenshi Yonezu 본인 채널은 그냥 "아티스트 - 곡명"으로만 올림, MV 표시 자체가 없음)
@pytest.mark.asyncio
async def test_resolve_youtube_artist_channel_without_any_official_marker():
    token = await _get_token()
    search_resp = _mock_response({"items": [{"id": {"videoId": "vid1"}}]})
    detail_resp = _mock_response(
        {
            "items": [
                {
                    "id": "vid1",
                    "snippet": {
                        "title": "Kenshi Yonezu - Lemon",
                        "channelTitle": "Kenshi Yonezu 米津玄師",
                        "description": "New Single release info...",
                    },
                },
            ]
        }
    )
    with patch.object(settings, "YOUTUBE_API_KEY", "key"):
        with _music_resolve_client_mock(get=[search_resp, detail_resp]):
            async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
                response = await ac.get(
                    "/api/v1/music-links/resolve",
                    params={"service": "youtube", "song": "Lemon", "artist": "Kenshi Yonezu"},
                    headers={"Authorization": f"Bearer {token}"},
                )
    assert response.json() == {"url": "https://www.youtube.com/watch?v=vid1"}


# 유튜브 - 아티스트 본인 채널이 아니라 신뢰 배급채널(1theK 등)이 올린 MV도 인정
# (실측: 잔나비 "for lovers who hesitate" MV가 1theK 채널에 올라와있었는데 "official" 단어가
# 아예 없었음 - 채널명은 정규화 부분일치라 "1theK (원더케이)"처럼 뒤에 텍스트가 붙어도 매칭됨)
@pytest.mark.asyncio
async def test_resolve_youtube_trusted_distributor_channel():
    token = await _get_token()
    search_resp = _mock_response({"items": [{"id": {"videoId": "vid1"}}]})
    detail_resp = _mock_response(
        {
            "items": [
                {
                    "id": "vid1",
                    "snippet": {
                        "title": "[MV] JANNABI(잔나비) _ for lovers who hesitate(주저하는 연인들을 위해)",
                        "channelTitle": "1theK (원더케이)",
                        "description": "",
                    },
                },
            ]
        }
    )
    with patch.object(settings, "YOUTUBE_API_KEY", "key"):
        with _music_resolve_client_mock(get=[search_resp, detail_resp]):
            async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
                response = await ac.get(
                    "/api/v1/music-links/resolve",
                    params={"service": "youtube", "song": "for lovers who hesitate", "artist": "잔나비"},
                    headers={"Authorization": f"Bearer {token}"},
                )
    assert response.json() == {"url": "https://www.youtube.com/watch?v=vid1"}


# 유튜브 - 신뢰 배급채널이어도 mv 표시가 없는 컨텐츠(댄스연습/직캠/티저 등)는 인정 안 함
@pytest.mark.asyncio
async def test_resolve_youtube_trusted_distributor_channel_without_mv_marker_returns_null():
    token = await _get_token()
    search_resp = _mock_response({"items": [{"id": {"videoId": "vid1"}}]})
    detail_resp = _mock_response(
        {
            "items": [
                {
                    "id": "vid1",
                    "snippet": {
                        "title": "JANNABI(잔나비) Dance Practice",
                        "channelTitle": "1theK (원더케이)",
                        "description": "",
                    },
                },
            ]
        }
    )
    with patch.object(settings, "YOUTUBE_API_KEY", "key"):
        with _music_resolve_client_mock(get=[search_resp, detail_resp]):
            async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
                response = await ac.get(
                    "/api/v1/music-links/resolve",
                    params={"service": "youtube", "song": "아무곡", "artist": "잔나비"},
                    headers={"Authorization": f"Bearer {token}"},
                )
    assert response.json() == {"url": None}


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


# 애플뮤직 - artistId가 일치하는 결과만 반환(문자열 유사도 대신 ID 대조로 교체됨 - 아래 3개
# 테스트 참고). 아티스트 검색으로 먼저 artistId를 확정하고, 곡 검색 결과 중 그 ID와 일치하는
# 것만 인정.
@pytest.mark.asyncio
async def test_resolve_apple_music_success():
    token = await _get_token()
    artist_resp = _mock_response({"results": [{"artistId": 111}]})
    song_resp = _mock_response(
        {
            "results": [
                {
                    "artistId": 111,
                    "artistName": "테스트가수",
                    "trackName": "테스트곡",
                    "trackViewUrl": "https://music.apple.com/us/song/123",
                }
            ]
        }
    )
    with _music_resolve_client_mock(get=[artist_resp, song_resp]):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                "/api/v1/music-links/resolve",
                params={"service": "apple_music", "song": "테스트곡", "artist": "테스트가수"},
                headers={"Authorization": f"Bearer {token}"},
            )
    assert response.json() == {"url": "https://music.apple.com/us/song/123"}


# 애플뮤직 - 곡 제목만 우연히 같은 무관한 아티스트 결과는 artistId가 달라서 걸러짐
# (실측 사례: 잔나비의 비공식 커버곡 "The Moon Represents My Heart" 검색 시 무관한 클래식
# 기타리스트의 동명 편곡 트랙이 잡혔던 실제 버그 - 문자열 유사도로는 90점 넘게 나와 오탐이었음).
# 일반 검색에서 못 찾으면 카탈로그 조회로 한 번 더 시도하므로(아래 참고) lookup도 빈 결과로 채움.
@pytest.mark.asyncio
async def test_resolve_apple_music_different_artist_id_returns_null():
    token = await _get_token()
    artist_resp = _mock_response({"results": [{"artistId": 111}]})
    song_resp = _mock_response(
        {
            "results": [
                {
                    "artistId": 999,
                    "artistName": "전혀 다른 아티스트",
                    "trackName": "테스트곡",  # 제목은 우연히 같아도
                    "trackViewUrl": "https://music.apple.com/us/song/999",
                }
            ]
        }
    )
    lookup_resp = _mock_response({"results": []})
    with _music_resolve_client_mock(get=[artist_resp, song_resp, lookup_resp]):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                "/api/v1/music-links/resolve",
                params={"service": "apple_music", "song": "테스트곡", "artist": "테스트가수"},
                headers={"Authorization": f"Bearer {token}"},
            )
    assert response.json() == {"url": None}


# 애플뮤직 - 일반 검색이 그 아티스트 명의로는 못 찾아도(노래방 커버가 검색순위를 차지하거나,
# 로마자 띄어쓰기가 카탈로그와 달라서), 아티스트 카탈로그 전체 조회 후 띄어쓰기/기호를 없애고
# 비교하면 찾아짐 (실측 사례: 쿼리 "Hana Uranai" ↔ Vaundy 카탈로그의 "hanauranai")
@pytest.mark.asyncio
async def test_resolve_apple_music_falls_back_to_catalog_lookup_for_spacing_mismatch():
    token = await _get_token()
    artist_resp = _mock_response({"results": [{"artistId": 111}]})
    song_resp = _mock_response({"results": []})  # 일반 검색은 못 찾음(노래방 커버 등에 밀림)
    catalog_resp = _mock_response(
        {
            "results": [
                {
                    "wrapperType": "track",
                    "artistId": 111,
                    "trackName": "hanauranai",  # 카탈로그 표기는 띄어쓰기 없음
                    "trackViewUrl": "https://music.apple.com/us/song/hanauranai",
                },
                {"wrapperType": "collection", "artistId": 111},  # 앨범 등 트랙 아닌 항목은 무시
            ]
        }
    )
    with _music_resolve_client_mock(get=[artist_resp, song_resp, catalog_resp]):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                "/api/v1/music-links/resolve",
                params={"service": "apple_music", "song": "Hana Uranai", "artist": "Vaundy"},
                headers={"Authorization": f"Bearer {token}"},
            )
    assert response.json() == {"url": "https://music.apple.com/us/song/hanauranai"}


# 애플뮤직 - 아티스트 검색 자체가 안 잡히면(존재하지 않는 아티스트 등) 곡 검색은 시도도 안 하고 null
@pytest.mark.asyncio
async def test_resolve_apple_music_artist_not_found_returns_null():
    token = await _get_token()
    artist_resp = _mock_response({"results": []})
    with _music_resolve_client_mock(get=artist_resp):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                "/api/v1/music-links/resolve",
                params={"service": "apple_music", "song": "테스트곡", "artist": "존재안하는아티스트"},
                headers={"Authorization": f"Bearer {token}"},
            )
    assert response.json() == {"url": None}


# 애플뮤직 - artist가 없으면(단독 공연 옛날 데이터 등) artistId 대조 자체가 불가능하므로
# API 호출 없이 바로 null
@pytest.mark.asyncio
async def test_resolve_apple_music_without_artist_returns_null():
    token = await _get_token()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        response = await ac.get(
            "/api/v1/music-links/resolve",
            params={"service": "apple_music", "song": "테스트곡"},
            headers={"Authorization": f"Bearer {token}"},
        )
    assert response.json() == {"url": None}


# 애플뮤직 - 같은 아티스트의 곡이 여러 버전(라이브 등)으로 잡히면 스튜디오 버전을 우선 채택
# (실측: "BTS Dynamite" 검색 1등이 "Dynamite (Live)"였던 사례)
@pytest.mark.asyncio
async def test_resolve_apple_music_prefers_studio_over_live_version():
    token = await _get_token()
    artist_resp = _mock_response({"results": [{"artistId": 111}]})
    song_resp = _mock_response(
        {
            "results": [
                {
                    "artistId": 111,
                    "trackName": "테스트곡 (Live)",
                    "trackViewUrl": "https://music.apple.com/us/song/live",
                },
                {
                    "artistId": 111,
                    "trackName": "테스트곡",
                    "trackViewUrl": "https://music.apple.com/us/song/studio",
                },
            ]
        }
    )
    with _music_resolve_client_mock(get=[artist_resp, song_resp]):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            response = await ac.get(
                "/api/v1/music-links/resolve",
                params={"service": "apple_music", "song": "테스트곡", "artist": "테스트가수"},
                headers={"Authorization": f"Bearer {token}"},
            )
    assert response.json() == {"url": "https://music.apple.com/us/song/studio"}
