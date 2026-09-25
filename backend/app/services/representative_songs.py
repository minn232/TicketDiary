import logging
import re
from datetime import datetime, timedelta, timezone

import httpx
from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.artist_normalization import ArtistGroupMembership, CanonicalArtist
from app.services.artist_normalization import find_canonical_by_alias
from app.services.lastfm import fetch_top_tracks
from app.services.music_resolve import _looks_like_alt_version
from app.services.musicbrainz import fetch_apple_music_artist_id
from app.services.setlistfm import _artist_matches

logger = logging.getLogger(__name__)

REPRESENTATIVE_SOURCE = "representative"
# anchor_confirmed_by 값 - "해당하는 iTunes 아티스트 없음"으로 확정(자동 확정도 다시 시도 안 함)
NO_ITUNES_ANCHOR = "none"

# 검색/곡 순서는 us 스토어(kr은 검색이 0건, us 순서는 인기순에 가까움), 표시 제목은 kr 스토어
# ID 재조회로 가져옴(us는 한국 곡도 "For Lovers Who Hesitate"처럼 영문 제목, kr은 한글 원제)
_ITUNES_COUNTRY = "us"
_ITUNES_TITLE_COUNTRY = "kr"
_ITUNES_LOOKUP_URL = "https://itunes.apple.com/lookup"
_ITUNES_SEARCH_URL = "https://itunes.apple.com/search"

# Last.fm만으로 대표곡을 채울 때의 품질 기준 - 무명 아티스트는 청취자 수십 명 이하에 잡음
# (뉴스 클립 제목 등)이 섞여 있어서, 이 기준을 못 넘으면 빈 채로 두는 게 나음
_LASTFM_MIN_TOP_LISTENERS = 50
_LASTFM_MIN_TRACKS = 5


# 같은 곡의 표기 차이(대소문자/공백/기호)를 묶는 키 - 한글/일본어 제목도 유지해야 해서
# a-z0-9만 남기는 music_resolve._normalize_title은 못 씀
def _title_key(title: str) -> str:
    return re.sub(r"\W", "", title.casefold())


# music_resolve의 라이브/리믹스 등에 더해, 한국 카탈로그에 흔한 반주 버전 표기도 제외
_EXTRA_ALT_MARKERS = ("inst.", "(mr)", "반주")


def _is_alt_version(title: str) -> bool:
    lower = title.lower()
    return _looks_like_alt_version(title) or any(marker in lower for marker in _EXTRA_ALT_MARKERS)


def _dedupe_titles(titles: list[str]) -> list[str]:
    seen: set[str] = set()
    result = []
    for title in titles:
        key = _title_key(title)
        if key and key not in seen and not _is_alt_version(title):
            seen.add(key)
            result.append(title)
    return result


# kr 스토어에서 같은 ID들(곡/아티스트)을 다시 조회해 (trackId -> 곡, artistId -> 아티스트).
# 실패하거나 kr에 없는 항목은 호출부가 us 값을 그대로 씀
async def _lookup_in_title_store(
    client: httpx.AsyncClient, track_ids: list[int], artist_ids: list[int] = ()
) -> tuple[dict[int, dict], dict[int, dict]]:
    ids = [*artist_ids, *track_ids]
    if not ids:
        return {}, {}
    try:
        response = await client.get(
            _ITUNES_LOOKUP_URL, params={"id": ",".join(map(str, ids)), "country": _ITUNES_TITLE_COUNTRY}
        )
        response.raise_for_status()
        results = response.json().get("results", [])
    except (httpx.HTTPError, ValueError) as e:
        logger.warning(f"iTunes kr 제목 조회 실패: {e}")
        return {}, {}
    tracks = {r["trackId"]: r for r in results if r.get("wrapperType") == "track" and r.get("trackId")}
    artists = {r["artistId"]: r for r in results if r.get("wrapperType") == "artist" and r.get("artistId")}
    return tracks, artists


# iTunes에 등록된 그 아티스트의 곡 목록(순서는 us, 제목은 kr, 다른 버전 제외, 중복 제거).
# 피처링으로만 참여한 남의 곡도 같이 오므로 아티스트 ID가 같은 곡만 씀. 실패 시 빈 리스트
async def fetch_itunes_artist_songs(itunes_artist_id: str) -> list[str]:
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.get(
                _ITUNES_LOOKUP_URL,
                params={"id": itunes_artist_id, "entity": "song", "limit": 200, "country": _ITUNES_COUNTRY},
            )
            response.raise_for_status()
            tracks = [
                r for r in response.json().get("results", [])
                if r.get("wrapperType") == "track" and str(r.get("artistId")) == itunes_artist_id
            ]
            titled, _ = await _lookup_in_title_store(client, [r["trackId"] for r in tracks if r.get("trackId")])
    except (httpx.HTTPError, ValueError) as e:
        logger.warning(f"iTunes 곡 목록 조회 실패 (artist_id={itunes_artist_id}): {e}")
        return []
    names = [(titled.get(r.get("trackId")) or r).get("trackName") for r in tracks]
    return _dedupe_titles([name for name in names if name])


# iTunes 아티스트 ID가 실제로 존재하는지 확인하고 그 이름을 반환(없으면 None)
async def fetch_itunes_artist_name(itunes_artist_id: str) -> str | None:
    async with httpx.AsyncClient(timeout=10.0) as client:
        response = await client.get(_ITUNES_LOOKUP_URL, params={"id": itunes_artist_id, "country": _ITUNES_COUNTRY})
    if response.status_code != 200:
        return None
    artist = next((r for r in response.json().get("results", []) if r.get("wrapperType") == "artist"), None)
    return artist.get("artistName") if artist else None


# 유저가 입력한 곡 제목으로 iTunes 곡 검색 - 앵커 후보(고르면 그 곡의 아티스트로 확정)
async def search_itunes_songs(term: str, limit: int = 25) -> list[dict]:
    async with httpx.AsyncClient(timeout=10.0) as client:
        response = await client.get(
            _ITUNES_SEARCH_URL,
            params={"term": term, "media": "music", "entity": "song", "country": _ITUNES_COUNTRY, "limit": limit},
        )
        if response.status_code != 200:
            raise HTTPException(status_code=502, detail="iTunes 검색에 실패했습니다.")
        results = [r for r in response.json().get("results", []) if r.get("artistId") and r.get("trackName")]
        titled, _ = await _lookup_in_title_store(client, [r["trackId"] for r in results if r.get("trackId")])

    candidates = []
    for r in results:
        shown = titled.get(r.get("trackId")) or r
        candidates.append({
            "itunes_artist_id": str(r["artistId"]),
            "artist_name": shown.get("artistName") or r.get("artistName", ""),
            "track_name": shown.get("trackName") or r["trackName"],
            "album_name": shown.get("collectionName") or r.get("collectionName"),
            "artwork_url": r.get("artworkUrl100"),
        })
    return candidates


# 공연 아티스트 이름으로 iTunes 아티스트 후보 검색(앵커용) - 동명이인은 장르/대표곡으로 구분하게
# 대표곡 3개를 붙임. 이름이 정확히 같은 후보를 앞으로. 호출 3번(검색/곡/kr 이름)이라 분당 제한
# (약 20회)을 넘지 않게 같은 이름은 하루 캐시
_ARTIST_CANDIDATE_CACHE_TTL = timedelta(days=1)
_artist_candidate_cache: dict[str, tuple[datetime, list[dict]]] = {}


async def search_itunes_artists(artist: str, limit: int = 8) -> list[dict]:
    key = _title_key(artist)
    cached = _artist_candidate_cache.get(key)
    if cached and datetime.now(timezone.utc) - cached[0] < _ARTIST_CANDIDATE_CACHE_TTL:
        return cached[1]

    async with httpx.AsyncClient(timeout=10.0) as client:
        response = await client.get(
            _ITUNES_SEARCH_URL,
            params={"term": artist, "entity": "musicArtist", "country": _ITUNES_COUNTRY, "limit": limit},
        )
        if response.status_code != 200:
            raise HTTPException(status_code=502, detail="iTunes 검색에 실패했습니다.")
        found = [a for a in response.json().get("results", []) if a.get("artistId")]
        if not found:
            _artist_candidate_cache[key] = (datetime.now(timezone.utc), [])
            return []

        artist_ids = [a["artistId"] for a in found]
        songs_response = await client.get(
            _ITUNES_LOOKUP_URL,
            params={"id": ",".join(map(str, artist_ids)), "entity": "song", "limit": 6, "country": _ITUNES_COUNTRY},
        )
        songs_response.raise_for_status()
        tracks = [r for r in songs_response.json().get("results", []) if r.get("wrapperType") == "track"]
        titled, kr_artists = await _lookup_in_title_store(client, [t["trackId"] for t in tracks], artist_ids)

    candidates = []
    for a in found:
        own = [t for t in tracks if t.get("artistId") == a["artistId"]]
        top_songs = _dedupe_titles([(titled.get(t["trackId"]) or t).get("trackName", "") for t in own])[:3]
        if not top_songs:
            continue  # 곡이 없으면 확정해도 대표곡을 못 채움
        # 한글 이름은 kr 아티스트 항목이 아니라 kr 곡 항목에 있음(아티스트 항목은 로마자 그대로)
        kr_track = next((titled[t["trackId"]] for t in own if t["trackId"] in titled), None)
        name = (kr_track or kr_artists.get(a["artistId"]) or a).get("artistName") or a.get("artistName", "")
        candidates.append({
            "itunes_artist_id": str(a["artistId"]),
            "artist_name": name,
            "genre": a.get("primaryGenreName"),
            "top_songs": top_songs,
            "artwork_url": own[0].get("artworkUrl100"),
            "exact_match": key in {_title_key(name), _title_key(a.get("artistName", ""))},
        })

    # 이름이 정확히 같은 후보를 앞으로(협업/편집 앨범 이름은 뒤로)
    candidates.sort(key=lambda c: not c["exact_match"])
    _artist_candidate_cache[key] = (datetime.now(timezone.utc), candidates)
    return candidates


# Last.fm 청취자 수가 있는 곡을 앞으로 정렬(나머지는 iTunes us 순서 그대로)
def _rank_by_listeners(titles: list[str], lastfm_tracks: list[tuple[str, int]]) -> list[str]:
    listeners = {_title_key(name): count for name, count in lastfm_tracks}
    return sorted(titles, key=lambda t: -listeners.get(_title_key(t), 0))


# mbid로 먼저, Last.fm이 그 mbid를 모르면 이름으로 조회. 이름 조회 결과는 같은 사람인지
# (setlistfm과 같은 기준: 같은 문자 체계 + 유사도) 확인된 것만 씀
async def _lastfm_top_tracks(artist: str, mbid: str | None) -> list[tuple[str, int]]:
    if mbid:
        _, tracks = await fetch_top_tracks(mbid=mbid)
        if tracks:
            return tracks
    resolved_name, tracks = await fetch_top_tracks(artist_name=artist)
    return tracks if _artist_matches(artist, resolved_name, None, None) else []


# 확정된 iTunes 아티스트가 없으면 MusicBrainz의 Apple Music 링크로 찾아서 canonical에 저장
async def _resolve_itunes_artist_id(db: AsyncSession, canonical: CanonicalArtist | None) -> str | None:
    if canonical is None:
        return None
    if canonical.itunes_artist_id or not canonical.mbid:
        return canonical.itunes_artist_id
    itunes_artist_id = await fetch_apple_music_artist_id(canonical.mbid)
    if itunes_artist_id:
        canonical.itunes_artist_id = itunes_artist_id
        canonical.anchor_confirmed_by = "musicbrainz"
        await db.commit()
    return itunes_artist_id


async def _is_band_member(db: AsyncSession, canonical: CanonicalArtist | None) -> bool:
    if canonical is None:
        return False
    result = await db.execute(
        select(ArtistGroupMembership.id).where(ArtistGroupMembership.member_canonical_id == canonical.id).limit(1)
    )
    return result.first() is not None


# iTunes에 이름이 정확히 같은 아티스트가 1명뿐이면 그 사람으로 자동 확정(동명이인이 여럿이면
# 유저가 고르게 둠). 밴드 멤버는 솔로 카탈로그가 없는 경우가 많아 동명이인이 잡히므로(실사례: NELL
# 이재경) 자동 확정 안 함 - 틀리면 유저가 화면의 "다른 아티스트예요?"로 다시 고름
async def _auto_anchor(db: AsyncSession, artist: str, canonical: CanonicalArtist | None) -> str | None:
    if await _is_band_member(db, canonical):
        return None
    try:
        candidates = await search_itunes_artists(artist)
    except (HTTPException, httpx.HTTPError, ValueError) as e:
        logger.warning(f"iTunes 아티스트 후보 조회 실패, 자동 확정 건너뜀 ({artist}): {e}")
        return None
    exact = [c for c in candidates if c["exact_match"]]
    if len(exact) != 1:
        return None
    await _save_anchor(db, artist, exact[0]["itunes_artist_id"], confirmed_by="auto")
    return exact[0]["itunes_artist_id"]


# 과거 셋리가 없는 아티스트의 대표곡 n개. 확정된 iTunes 아티스트(유저/MusicBrainz 링크/자동)가
# 있으면 그 곡 목록(Last.fm 청취자 순), 없으면 Last.fm 인기곡(품질 기준 통과 시만)
async def representative_songs_for_artist(db: AsyncSession, artist: str, n: int) -> list[dict]:
    canonical = await find_canonical_by_alias(db, artist)
    mbid = canonical.mbid if canonical is not None else None
    if canonical is not None and canonical.anchor_confirmed_by == NO_ITUNES_ANCHOR:
        itunes_artist_id = None
    else:
        itunes_artist_id = await _resolve_itunes_artist_id(db, canonical) or await _auto_anchor(db, artist, canonical)
    lastfm_tracks = await _lastfm_top_tracks(artist, mbid)

    titles: list[str] = []
    if itunes_artist_id:
        titles = _rank_by_listeners(await fetch_itunes_artist_songs(itunes_artist_id), lastfm_tracks)
    if not titles and len(lastfm_tracks) >= _LASTFM_MIN_TRACKS:
        if max(count for _, count in lastfm_tracks) >= _LASTFM_MIN_TOP_LISTENERS:
            titles = _dedupe_titles([name for name, _ in lastfm_tracks])

    return [{"name": title, "encore": False, "source": REPRESENTATIVE_SOURCE} for title in titles[:n]]


# canonical에 iTunes 아티스트 확정값 저장(itunes_artist_id=None이면 "없음"으로 확정) - canonical이
# 없던 아티스트(MusicBrainz 미등록 등)면 새로 만듦
async def _save_anchor(
    db: AsyncSession, artist: str, itunes_artist_id: str | None, confirmed_by: str
) -> CanonicalArtist:
    canonical = await find_canonical_by_alias(db, artist)
    if canonical is None:
        canonical = CanonicalArtist(mbid=None, canonical_name=artist.strip())
        db.add(canonical)
    canonical.itunes_artist_id = itunes_artist_id
    canonical.anchor_confirmed_by = confirmed_by
    await db.commit()
    await db.refresh(canonical)
    return canonical


# 유저가 고른 iTunes 아티스트로 확정 - 잘못 고른 경우는 추후 수정 기능에서 다룰 예정이라 바로 확정함
async def set_itunes_anchor(db: AsyncSession, artist: str, itunes_artist_id: str) -> CanonicalArtist:
    if await fetch_itunes_artist_name(itunes_artist_id) is None:
        raise HTTPException(status_code=400, detail="iTunes 아티스트를 찾을 수 없습니다.")
    return await _save_anchor(db, artist, itunes_artist_id, confirmed_by="user")
