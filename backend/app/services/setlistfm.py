import asyncio
import re
from datetime import date

import httpx
from fastapi import HTTPException
from rapidfuzz import fuzz, utils

from app.core.config import settings

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


# 검색어와 Setlist.fm이 돌려준 후보의 실제 아티스트명(raw["artist"]["name"])이 같은
# 아티스트로 보이는지 확인. 짧거나 흔한 이름("Nell")으로 검색하면 Setlist.fm이 부분/유사
# 일치로 전혀 다른 아티스트(Nell Mescal, Nellie McKay 등)를 같이 섞어서 돌려주는 걸 실측으로
# 확인해서 추가함.
#
# 문자 체계(한글/로마자)가 다르면 판단을 보류(True)함 - Setlist.fm이 한글->로마자 음차
# 변환을 자체적으로 처리해주는 걸 실측으로 확인했고(예: "넬" 검색 시 100/100 정확히
# "NELL"), 여기서 단순 문자열 유사도로 그 변환까지 검증하려 하면 정답까지 걸러내는
# 역효과가 남(fuzz.ratio("넬", "NELL") == 0). 대신 KOPIS가 드물게 로마자 아티스트명을
# 그대로 주는 경우(같은 체계일 때)만 유사도로 걸러서, "Nell" 검색에 다른 아티스트가
# 섞이는 문제를 막음. 완전한 동명이인(문자열 자체가 같은 경우)이나 극단적으로 짧은
# 한글(1글자) 검색어가 로마자로 변환되며 우연히 흔한 이름과 겹치는 경우까지는 못 잡음 -
# 실사용 아티스트명이 보통 이보다는 길어서 남겨둔 잔여 위험으로 판단함.
def _artist_name_matches(query: str, candidate_name: str) -> bool:
    if not candidate_name:
        return False
    if bool(_HANGUL_RE.search(query)) != bool(_HANGUL_RE.search(candidate_name)):
        return True
    return fuzz.ratio(query, candidate_name, processor=utils.default_process) >= _ARTIST_MATCH_THRESHOLD


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


# Setlist.fm 셋리스트 검색 (아티스트명 + 공연일)
async def search_setlists(artist_name: str, event_date: date) -> list[dict]:
    params = {
        "artistName": artist_name,
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
    candidates = [parse_candidate(s) for s in raw_list]
    return [c for c in candidates if _artist_name_matches(artist_name, c["artist_name"])]


# 아티스트의 과거 공연 셋리스트를 여러 페이지에 걸쳐 가져옴
# (클라이언트를 루프 밖에서 하나만 만들어 페이지마다 재사용, 매번 새 TCP/TLS 핸드셰이크 방지)
async def search_setlists_by_artist(artist_name: str, pages: int = 3) -> list[dict]:
    all_setlists = []
    async with httpx.AsyncClient(timeout=10.0) as client:
        for page in range(1, pages + 1):
            if page > 1:
                await asyncio.sleep(0.5)

            params = {"artistName": artist_name, "p": page}
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
            all_setlists.extend(
                s for s in setlists
                if _artist_name_matches(artist_name, (s.get("artist") or {}).get("name", ""))
            )

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
