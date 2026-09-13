import base64
import logging
import re
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
# Official MV) 놓치는 문제가 있었음 - 제목에 "official"+"mv/music video" 조합이 있으면 추가로
# 인정.
_OFFICIAL_MV_TITLE_MARKERS = ("mv", "m/v", "music video")

# 아티스트 본인 채널이 아니라 방송사/배급사가 올리는 공식 MV는(실측: 잔나비 MV가 "1theK"
# 채널에 올라와있었는데 "official" 단어가 아예 없었음) 채널 자체를 신뢰의 근거로 삼음.
# 정확한 채널명이 아니라 정규화(공백/기호 제거 후 소문자)한 부분일치라 "Sony Music (Japan)"
# 처럼 지역명이 붙거나 "warnermusichk"처럼 붙여쓴 변형에도 대응됨.
_TRUSTED_DISTRIBUTOR_CHANNEL_MARKERS = (
    # 국내 K-pop 배급/방송 채널
    "1thek", "smtown", "jypentertainment", "ygentertainment", "hybelabels",
    "mnetkpop", "kbskpop", "mbckpop", "sbskpop",
    # 해외 메이저 레이블/배급(Vevo는 아티스트별 채널명이 "{아티스트}VEVO" 식이라 이 부분
    # 일치만으로 그 아티스트별 채널까지 함께 커버됨)
    "vevo", "avex", "sonymusic", "universalmusic", "warnermusic",
)


def _is_trusted_distributor_channel(channel_title: str) -> bool:
    return any(marker in _normalize_title(channel_title) for marker in _TRUSTED_DISTRIBUTOR_CHANNEL_MARKERS)


def _looks_like_official_video(title: str, description: str, channel_title: str, artist: str | None) -> bool:
    if _OFFICIAL_AUDIO_MARKER in description:
        return True
    title_lower = title.lower()
    has_mv_marker = any(marker in title_lower for marker in _OFFICIAL_MV_TITLE_MARKERS)
    if "official" in title_lower and has_mv_marker:
        return True
    # 채널이 검색한 아티스트 본인 채널이면(자체 업로드), 제목에 "official"/"mv" 표시가 전혀
    # 없어도 인정 - 실측으로 표시 문구 관행이 아티스트마다 다 달랐음: Vaundy는 "official" 없이
    # "MUSIC VIDEO"만, 요네즈 켄시(Kenshi Yonezu)는 그마저도 없이 그냥 "아티스트 - 곡명"으로만
    # 올림. 특정 문구를 계속 추가하기보다 "본인 채널이 올린 것"이라는 사실 자체를 신뢰.
    if artist and channel_title:
        artist_lower = artist.lower()
        channel_lower = channel_title.lower()
        if artist_lower in channel_lower or channel_lower in artist_lower:
            return True
    # 방송사/배급 채널은 한 채널에 여러 컨텐츠 유형(직캠/댄스연습/티저 등)이 섞여있어서,
    # 아티스트 본인 채널과 달리 제목에 mv 표시가 있는지는 그대로 확인.
    return has_mv_marker and _is_trusted_distributor_channel(channel_title)


# 공식으로 인정된 영상 중에서도 "오디오만" 올라간 것(Content ID 자동생성 오디오, 정적 이미지)과
# 실제 뮤직비디오를 구분 - 유튜브로 누르면 무대/영상을 보고 싶은 거지 오디오만 나오는 걸
# 기대하는 게 아니라서, 뮤비가 후보에 있으면 그쪽을 우선함.
def _is_audio_only(title: str, description: str) -> bool:
    title_lower = title.lower()
    if "audio" in title_lower:  # "(Official Audio)"처럼 직접 명시하는 경우
        return True
    # Content ID 자동생성 오디오는 보통 제목에 MV 표시가 없음 - 있으면(제목에 mv 표시가
    # 있는데 설명란에도 저 문구가 있는 경우) 뮤비 쪽으로 봄.
    has_mv_marker = any(marker in title_lower for marker in _OFFICIAL_MV_TITLE_MARKERS)
    return _OFFICIAL_AUDIO_MARKER in description and not has_mv_marker


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
        official_candidates: list[tuple[str, bool]] = []  # (videoId, 오디오만인지)
        for item in detail_resp.json().get("items", []):
            snippet = item.get("snippet", {})
            description = (snippet.get("description") or "").lower()
            title = snippet.get("title") or ""
            channel_title = snippet.get("channelTitle") or ""
            if _looks_like_official_video(title, description, channel_title, artist):
                official_candidates.append((item["id"], _is_audio_only(title, description)))

        if not official_candidates:
            return None  # 공식 음원/뮤비 표시가 없음(커버/직캠 등) -> 검색화면 폴백

        # 뮤비 후보가 있으면 우선 채택(유튜브로 누르는 건 보통 영상을 보고 싶은 거라서),
        # 없으면 오디오만이라도 씀.
        video = next((vid for vid, audio_only in official_candidates if not audio_only), None)
        return video or official_candidates[0][0]
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

            # 일반 검색이 그 아티스트 명의로는 못 찾았을 때의 2차 시도 - 실측(일본 아티스트
            # Vaundy)으로 두 가지 이유가 확인됨: ①노래방 커버 채널들이 아티스트명을 여러 번
            # 반복 언급해 검색 순위를 차지해버림 ②로마자 표기 띄어쓰기가 카탈로그마다 달라서
            # (예: 쿼리 "Hana Uranai" ↔ 카탈로그 "hanauranai") 일반 검색에 안 걸릴 수 있음.
            # artistId로 그 아티스트의 곡 전체를 받아와 띄어쓰기/기호 없이 비교하면 이 두 문제
            # 다 피해감.
            if not matches:
                catalog_resp = await client.get(
                    "https://itunes.apple.com/lookup",
                    params={"id": artist_id, "entity": "song", "limit": 200, "country": country},
                )
                catalog_resp.raise_for_status()
                target = _normalize_title(song)
                matches = [
                    item
                    for item in catalog_resp.json().get("results", [])
                    if item.get("wrapperType") == "track" and _normalize_title(item.get("trackName", "")) == target
                ]

        if not matches:
            return None  # 그 아티스트 명의로는 정말 없음(커버/미발매곡 등) -> 검색화면 폴백

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


def _normalize_title(text: str) -> str:
    return re.sub(r"[^a-z0-9]", "", (text or "").lower())
