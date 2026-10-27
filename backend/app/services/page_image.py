import asyncio
import logging
import re

import httpx

logger = logging.getLogger(__name__)

# MusicBrainz가 mbid에 걸어둔 벅스 아티스트/YouTube 채널 페이지의 대표 이미지(og:image)를 쓰는
# 사진 대체 경로 - Spotify 링크가 없는 국내 아티스트가 많아서 추가함. mbid로 확정된 URL만 열어서
# 이름 검색과 달리 동명이인 위험 없음
_MIN_REQUEST_INTERVAL = 1.0
_USER_AGENT = "Mozilla/5.0 (compatible; TicketDiaryBot/1.0)"

# 페이지 종류별 (URL, 허용 이미지 호스트, 실제 사진 표시) - 허용 호스트로 엉뚱한 배너/로고를 막고,
# 벅스는 사진 없는 아티스트도 이니셜 기본 이미지를 같은 주소 형식으로 줘서 사진첩 링크
# (openPageLayer)가 있을 때만 실제 사진으로 봄
_PAGE_RULES = (
    (
        re.compile(r"^https?://music\.bugs\.co\.kr/artist/\d+"),
        ("image.bugsm.co.kr",),
        re.compile(r"openPageLayer\("),
    ),
    (
        re.compile(r"^https?://(www\.)?youtube\.com/(channel/|@|c/|user/)"),
        ("yt3.googleusercontent.com", "yt3.ggpht.com"),
        None,
    ),
)
_OG_IMAGE_RE = re.compile(r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"', re.IGNORECASE)

_request_lock = asyncio.Lock()
_last_request_at = 0.0


async def _throttle() -> None:
    global _last_request_at
    async with _request_lock:
        loop = asyncio.get_event_loop()
        now = loop.time()
        wait = _last_request_at + _MIN_REQUEST_INTERVAL - now
        if wait > 0:
            await asyncio.sleep(wait)
        _last_request_at = loop.time()


def is_supported_page(url: str) -> bool:
    return any(pattern.match(url) for pattern, _, _ in _PAGE_RULES)


# 지원하는 페이지(벅스 아티스트/YouTube 채널)의 og:image를 반환. 지원 안 하는 URL, 실패,
# 허용 호스트가 아니거나 실제 사진 표시가 없으면(기본 이미지) None
async def fetch_page_image(page_url: str, client: httpx.AsyncClient | None = None) -> str | None:
    rule = next((r for r in _PAGE_RULES if r[0].match(page_url)), None)
    if rule is None:
        return None
    _, hosts, photo_marker = rule

    async def _fetch(c: httpx.AsyncClient) -> str | None:
        await _throttle()
        try:
            response = await c.get(page_url, headers={"User-Agent": _USER_AGENT}, follow_redirects=True)
        except httpx.HTTPError as e:
            logger.warning(f"페이지 대표 이미지 조회 실패 ({page_url}): {e}")
            return None
        if response.status_code != 200:
            return None
        match = _OG_IMAGE_RE.search(response.text)
        if not match or (photo_marker is not None and not photo_marker.search(response.text)):
            return None
        image_url = match.group(1).replace("&amp;", "&")
        if httpx.URL(image_url).host not in hosts:
            return None
        return image_url

    if client is not None:
        return await _fetch(client)
    async with httpx.AsyncClient(timeout=10.0) as c:
        return await _fetch(c)
