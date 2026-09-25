import asyncio
import re
from datetime import date

import httpx
from fastapi import HTTPException
from rapidfuzz import fuzz, utils

from app.core.config import settings
from app.services.musicbrainz import fetch_current_mbid

_HEADERS = {
    "x-api-key": settings.SETLISTFM_API_KEY,
    "Accept": "application/json",
}

_HANGUL_RE = re.compile(r"[가-힣]")

# artist_matching.py와 같은 라이브러리/threshold 스타일(그쪽은 DB 내 아티스트명 중복 판단용,
# 여기는 Setlist.fm 검색 결과 검증용이라 목적은 다름). 92처럼 빡빡하게 잡을 필요는 없음 -
# 여기서 걸러야 할 건 "Nell" vs "Nell Mescal"(53점대) 같은 명백히 다른 아티스트라, 정답
# (거의 100점)과 오답 사이 여유가 넉넉함.
_ARTIST_MATCH_THRESHOLD = 70


# 후보가 검색한 아티스트 본인인지 확인. Setlist.fm은 MusicBrainz 별칭(본명 포함)으로도 검색돼서
# "김지수"→JISOO처럼 이름만 같은 사람이 섞이므로 canonical mbid를 알면 mbid로만 판정함. mbid를
# 모르면 같은 문자 체계끼리만 유사도 비교("Nell" vs "Nell Mescal"), 한글↔로마자는 거절
def _artist_matches(
    query: str, candidate_name: str, candidate_mbid: str | None, expected_mbid: str | None
) -> bool:
    if not candidate_name:
        return False
    if expected_mbid:
        return candidate_mbid == expected_mbid
    if bool(_HANGUL_RE.search(query)) != bool(_HANGUL_RE.search(candidate_name)):
        return False
    return fuzz.ratio(query, candidate_name, processor=utils.default_process) >= _ARTIST_MATCH_THRESHOLD


# Setlist.fm mbid -> MusicBrainz 현재 mbid(병합 반영). 같은 mbid를 매 검색마다 다시 묻지 않게 캐시
_current_mbid_cache: dict[str, str] = {}


async def _current_mbid(mbid: str) -> str:
    if mbid not in _current_mbid_cache:
        current = await fetch_current_mbid(mbid)
        if current is None:
            return mbid  # 조회 실패는 캐시 안 함(다음 검색에서 재시도)
        _current_mbid_cache[mbid] = current
    return _current_mbid_cache[mbid]


# 검색 결과 중 본인 셋리만 남김. mbid가 다른 후보는 MusicBrainz 병합으로 옛 mbid가 남은 경우일
# 수 있어서 현재 mbid로 바꿔 한 번 더 비교
async def _filter_matching(query: str, raw_list: list[dict], expected_mbid: str | None) -> list[dict]:
    merged: dict[str, str] = {}
    if expected_mbid:
        for raw in raw_list:
            mbid = (raw.get("artist") or {}).get("mbid")
            if mbid and mbid != expected_mbid and mbid not in merged:
                merged[mbid] = await _current_mbid(mbid)

    matched = []
    for raw in raw_list:
        artist = raw.get("artist") or {}
        mbid = artist.get("mbid")
        if _artist_matches(query, artist.get("name", ""), merged.get(mbid, mbid), expected_mbid):
            matched.append(raw)
    return matched


# Setlist.fm API 응답에서 곡 목록 추출 (앙코르 여부 포함)
def extract_songs(setlist_data: dict) -> list[dict]:
    songs = []
    for s in setlist_data.get("sets", {}).get("set", []):
        is_encore = s.get("encore") is not None
        for song in s.get("song", []):
            name = (song.get("name") or "").strip()
            if name:
                songs.append({"name": name, "encore": is_encore})
    return songs


# Setlist.fm 검색 결과를 후보 형식으로 변환
def parse_candidate(raw: dict) -> dict:
    songs = extract_songs(raw)
    venue = raw.get("venue") or {}
    city = venue.get("city") or {}
    return {
        "setlistfm_id": raw.get("id", ""),
        "event_date": raw.get("eventDate", ""),
        "artist_name": (raw.get("artist") or {}).get("name", ""),
        "venue_name": venue.get("name", ""),
        "city_name": city.get("name", ""),
        "song_count": len(songs),
        "songs": songs,
        "url": raw.get("url", ""),
    }


# 검색 조건 - by_mbid면 이름 대신 mbid로 검색(한글 표기로는 0건인 아티스트용)
def _artist_param(artist_name: str, artist_mbid: str | None, by_mbid: bool) -> dict:
    return {"artistMbid": artist_mbid} if by_mbid else {"artistName": artist_name}


# Setlist.fm 셋리스트 검색 (아티스트명 + 공연일), artist_mbid는 우리 canonical의 mbid(모르면 None)
async def search_setlists(
    artist_name: str, event_date: date, artist_mbid: str | None = None, *, by_mbid: bool = False
) -> list[dict]:
    params = {
        **_artist_param(artist_name, artist_mbid, by_mbid),
        "date": event_date.strftime("%d-%m-%Y"),
        "p": 1,
    }

    async with httpx.AsyncClient(timeout=10.0) as client:
        response = await client.get(
            f"{settings.SETLISTFM_BASE_URL}/search/setlists",
            headers=_HEADERS,
            params=params,
        )

    # 결과 없음
    if response.status_code == 404:
        return []
    if response.status_code != 200:
        raise HTTPException(status_code=502, detail="Setlist.fm API 호출에 실패했습니다.")

    raw_list = response.json().get("setlist", [])
    return [parse_candidate(s) for s in await _filter_matching(artist_name, raw_list, artist_mbid)]


# 아티스트의 과거 공연 셋리스트를 여러 페이지에 걸쳐 가져옴
# (클라이언트를 루프 밖에서 하나만 만들어 페이지마다 재사용, 매번 새 TCP/TLS 핸드셰이크 방지)
async def search_setlists_by_artist(
    artist_name: str, pages: int = 3, artist_mbid: str | None = None, *, by_mbid: bool = False
) -> list[dict]:
    all_setlists = []
    async with httpx.AsyncClient(timeout=10.0) as client:
        for page in range(1, pages + 1):
            if page > 1:
                await asyncio.sleep(0.5)

            params = {**_artist_param(artist_name, artist_mbid, by_mbid), "p": page}
            response = await client.get(
                f"{settings.SETLISTFM_BASE_URL}/search/setlists",
                headers=_HEADERS,
                params=params,
            )

            if response.status_code == 404:
                break
            if response.status_code != 200:
                raise HTTPException(status_code=502, detail="Setlist.fm API 호출에 실패했습니다.")

            data = response.json()
            setlists = data.get("setlist", [])
            all_setlists.extend(await _filter_matching(artist_name, setlists, artist_mbid))

            total = data.get("total", 0)
            items_per_page = data.get("itemsPerPage", 20)
            if page * items_per_page >= total:
                break

    return all_setlists


# Setlist.fm ID로 셋리스트 상세 조회
async def get_setlist_by_id(setlistfm_id: str) -> dict:
    async with httpx.AsyncClient(timeout=10.0) as client:
        response = await client.get(
            f"{settings.SETLISTFM_BASE_URL}/setlist/{setlistfm_id}",
            headers=_HEADERS,
        )

    if response.status_code == 404:
        raise HTTPException(status_code=404, detail="해당 셋리스트를 찾을 수 없습니다.")
    if response.status_code != 200:
        raise HTTPException(status_code=502, detail="Setlist.fm API 호출에 실패했습니다.")

    return response.json()
