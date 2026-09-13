import base64
import logging
import time

import httpx
from rapidfuzz import fuzz

from app.core.config import settings

logger = logging.getLogger(__name__)

_HTTP_TIMEOUT = 8.0


# ---- Spotify ----

# Client Credentials 토큰은 만료 전까지 프로세스 전역에서 재사용(수명 1시간짜리를 매
# 요청마다 새로 받으면 낭비) - 프로세스 재시작 전까지만 유지되면 충분.
_spotify_token: str | None = None
_spotify_token_expires_at: float = 0.0


async def _get_spotify_token() -> str | None:
    global _spotify_token, _spotify_token_expires_at
    if not settings.SPOTIFY_CLIENT_ID or not settings.SPOTIFY_CLIENT_SECRET:
        return None
    if _spotify_token and time.time() < _spotify_token_expires_at:
        return _spotify_token

    auth = base64.b64encode(
        f"{settings.SPOTIFY_CLIENT_ID}:{settings.SPOTIFY_CLIENT_SECRET}".encode()
    ).decode()
    try:
        async with httpx.AsyncClient(timeout=_HTTP_TIMEOUT) as client:
            resp = await client.post(
                "https://accounts.spotify.com/api/token",
                data={"grant_type": "client_credentials"},
                headers={"Authorization": f"Basic {auth}"},
            )
        resp.raise_for_status()
        data = resp.json()
        _spotify_token = data["access_token"]
        _spotify_token_expires_at = time.time() + data["expires_in"] - 60  # 만료 1분 전 갱신
        return _spotify_token
    except Exception as e:
        logger.warning(f"Spotify 토큰 발급 실패: {e}")
        return None


# artist:/track: 필드 검색으로 Spotify 자체 매칭엔진에 맡김 - 우리가 직접 문자열 유사도로
# 비교하면 로마자/번역 표기 때문에(예: "for lovers who hesitate" ↔ "주저하는 연인들을 위해")
# 정상 매칭도 걸러질 위험이 커서(실측 확인) 안 씀. 필드 검색 자체가 안 걸리면(비공식/미발매곡)
# None -> 검색화면 폴백.
async def resolve_spotify_track(artist: str | None, song: str) -> str | None:
    token = await _get_spotify_token()
    if token is None:
        return None

    query = f'track:"{song}"'
    if artist:
        query += f' artist:"{artist}"'

    try:
        async with httpx.AsyncClient(timeout=_HTTP_TIMEOUT) as client:
            resp = await client.get(
                "https://api.spotify.com/v1/search",
                params={"q": query, "type": "track", "limit": 1},
                headers={"Authorization": f"Bearer {token}"},
            )
        resp.raise_for_status()
        items = resp.json().get("tracks", {}).get("items", [])
        return items[0]["external_urls"]["spotify"] if items else None
    except Exception as e:
        logger.warning(f"Spotify 검색 실패 (artist={artist}, song={song}): {e}")
        return None


# ---- YouTube ----

# Content ID로 정식 유통 등록된 음원에 유튜브가 자동으로 붙이는 표준 문구 - 유명세와 무관하게
# 저가 유통사(디스트로킷 등)를 쓴 인디 아티스트도 대부분 해당됨. 채널명이 "-Topic"으로
# 끝나는지를 볼까 했지만, 공식 음원이 아티스트 브랜드 채널에도 올라가는 경우가 있어(실측
# 확인) 신뢰도가 낮아 안 씀.
_OFFICIAL_AUDIO_MARKER = "provided to youtube by"


# 유튜브/유튜브뮤직은 카탈로그(영상 ID)가 같아서 검색 로직은 공유하고, 링크 도메인만 다르게
# 붙임 - 유튜브는 "그 무대 영상/직캠 보기", 유튜브뮤직은 "음악만 바로 듣기" 용도로 구분해서
# 쓰라는 요청 반영.
async def _find_official_youtube_video_id(artist: str | None, song: str) -> str | None:
    if not settings.YOUTUBE_API_KEY:
        return None

    query = f"{artist} {song}".strip() if artist else song
    try:
        async with httpx.AsyncClient(timeout=_HTTP_TIMEOUT) as client:
            search_resp = await client.get(
                "https://www.googleapis.com/youtube/v3/search",
                params={
                    "part": "snippet",
                    "q": query,
                    "type": "video",
                    "maxResults": 5,
                    "key": settings.YOUTUBE_API_KEY,
                },
            )
            search_resp.raise_for_status()
            video_ids = [item["id"]["videoId"] for item in search_resp.json().get("items", [])]
            if not video_ids:
                return None

            detail_resp = await client.get(
                "https://www.googleapis.com/youtube/v3/videos",
                params={"part": "snippet", "id": ",".join(video_ids), "key": settings.YOUTUBE_API_KEY},
            )
        detail_resp.raise_for_status()
        for item in detail_resp.json().get("items", []):
            description = (item.get("snippet", {}).get("description") or "").lower()
            if _OFFICIAL_AUDIO_MARKER in description:
                return item["id"]
        return None  # 검색 결과는 있지만 공식 음원 표시가 없음(커버/직캠 등) -> 검색화면 폴백
    except Exception as e:
        logger.warning(f"YouTube 검색 실패 (artist={artist}, song={song}): {e}")
        return None


async def resolve_youtube_video(artist: str | None, song: str) -> str | None:
    video_id = await _find_official_youtube_video_id(artist, song)
    return f"https://www.youtube.com/watch?v={video_id}" if video_id else None


async def resolve_youtube_music_video(artist: str | None, song: str) -> str | None:
    video_id = await _find_official_youtube_video_id(artist, song)
    return f"https://music.youtube.com/watch?v={video_id}" if video_id else None


# ---- Apple Music (iTunes Search API, 인증 불필요) ----

# 스포티파이와 달리 artist:/track: 필드 검색이 없어서 결과를 문자열 유사도로 걸러야 함 -
# 로마자/번역 표기 케이스를 놓칠 수 있는 만큼 임계치를 낮게 잡아 안전 쪽(폴백)으로 치우침.
_APPLE_MUSIC_MATCH_THRESHOLD = 45


async def resolve_apple_music_track(
    artist: str | None, song: str, country: str = "kr"
) -> str | None:
    query = f"{artist} {song}".strip() if artist else song
    try:
        async with httpx.AsyncClient(timeout=_HTTP_TIMEOUT) as client:
            resp = await client.get(
                "https://itunes.apple.com/search",
                params={
                    "term": query,
                    "media": "music",
                    "entity": "song",
                    "country": country,
                    "limit": 5,
                },
            )
        resp.raise_for_status()
        for item in resp.json().get("results", []):
            candidate = f"{item.get('artistName', '')} {item.get('trackName', '')}"
            if fuzz.partial_ratio(query.lower(), candidate.lower()) >= _APPLE_MUSIC_MATCH_THRESHOLD:
                return item.get("trackViewUrl")
        return None
    except Exception as e:
        logger.warning(f"Apple Music 검색 실패 (artist={artist}, song={song}): {e}")
        return None
