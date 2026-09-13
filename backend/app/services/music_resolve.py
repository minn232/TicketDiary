import base64
import logging
import time

import httpx

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

# Content ID가 정식 유통 음원에 자동으로 붙이는 표준 문구 - 유명세와 무관하게 저가
# 유통사를 쓴 인디 아티스트도 대부분 해당됨. 채널명 "-Topic" 패턴은 공식 음원이 아티스트
# 브랜드 채널에도 올라가는 경우가 있어(실측 확인) 신뢰도가 낮아 안 씀.
_OFFICIAL_AUDIO_MARKER = "provided to youtube by"

# 레이블이 직접 편집해 올리는 "공식 뮤직비디오"는 위 문구가 없어서(실측: BTS 'Dynamite'
# Official MV) 놓치는 문제가 있었음 - 제목에 "official"+"mv/music video" 조합이 있으면
# 추가로 인정.
_OFFICIAL_MV_TITLE_MARKERS = ("mv", "m/v", "music video")


def _looks_like_official_video(title: str, description: str) -> bool:
    if _OFFICIAL_AUDIO_MARKER in description:
        return True
    title_lower = title.lower()
    return "official" in title_lower and any(marker in title_lower for marker in _OFFICIAL_MV_TITLE_MARKERS)


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
            snippet = item.get("snippet", {})
            description = (snippet.get("description") or "").lower()
            title = snippet.get("title") or ""
            if _looks_like_official_video(title, description):
                return item["id"]
        return None  # 검색 결과는 있지만 공식 음원/뮤비 표시가 없음(커버/직캠 등) -> 검색화면 폴백
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

# country="kr"은 실측 결과 BTS/아이유 등 유명 아티스트도 resultCount=0이라(iTunes 한국
# 스토어프론트가 이 API로는 거의 안 됨) "us"로 변경.
#
# 문자열 유사도(rapidfuzz) 대신 artistId 대조를 쓰는 이유: 로마자/번역 표기 정상매칭은
# 유사도가 0에 가깝게 나와 거절되고(예: "아이유 좋은날" ↔ "IU Good Day"), 반대로 곡 제목만
# 같은 무관한 아티스트는 유사도가 높게 나와 오탐(실측: 잔나비 비공식 커버곡 검색 시 무관한
# 클래식 기타리스트 동명곡이 90점대로 통과) - 임계치 조정으로는 둘 다 못 잡음. 그래서 iTunes
# 아티스트 전용 검색으로 artistId를 먼저 확정하고, 곡 검색 결과 중 그 ID와 일치하는 것만
# 인정하는 방식으로 교체(숫자 ID라 스크립트 차이 무관).
async def resolve_apple_music_track(
    artist: str | None, song: str, country: str = "us"
) -> str | None:
    # 아티스트 정보가 없으면 artistId 대조 자체가 불가능해서, 곡명만으로 억지로 추정하는 대신
    # 그냥 폴백(검색화면).
    if not artist:
        return None

    try:
        async with httpx.AsyncClient(timeout=_HTTP_TIMEOUT) as client:
            artist_resp = await client.get(
                "https://itunes.apple.com/search",
                params={"term": artist, "entity": "musicArtist", "country": country, "limit": 1},
            )
            artist_resp.raise_for_status()
            artist_results = artist_resp.json().get("results", [])
            if not artist_results:
                return None
            artist_id = artist_results[0].get("artistId")

            song_resp = await client.get(
                "https://itunes.apple.com/search",
                params={
                    "term": f"{artist} {song}",
                    "media": "music",
                    "entity": "song",
                    "country": country,
                    "limit": 10,
                },
            )
        song_resp.raise_for_status()

        matches = [
            item for item in song_resp.json().get("results", []) if item.get("artistId") == artist_id
        ]
        if not matches:
            return None  # 검색은 됐지만 그 아티스트 명의로는 없음(커버/미발매곡 등) -> 폴백

        # 같은 곡의 라이브/인스트루멘탈/리믹스 버전이 스튜디오 버전보다 먼저 나오는 경우가
        # 있어서(실측: "BTS Dynamite" 1등이 "Dynamite (Live)"), 그런 표시가 없는 버전을
        # 우선 채택하고 없으면 그냥 1등 그대로 씀.
        studio = next((m for m in matches if not _looks_like_alt_version(m.get("trackName", ""))), None)
        return (studio or matches[0]).get("trackViewUrl")
    except Exception as e:
        logger.warning(f"Apple Music 검색 실패 (artist={artist}, song={song}): {e}")
        return None


_ALT_VERSION_MARKERS = ("live", "instrumental", "remix", "acoustic", "karaoke")


def _looks_like_alt_version(track_name: str) -> bool:
    lower = track_name.lower()
    return any(marker in lower for marker in _ALT_VERSION_MARKERS)
