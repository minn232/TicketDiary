import asyncio
from datetime import date

import httpx
from fastapi import HTTPException

from app.core.config import settings

_HEADERS = {
    "x-api-key": settings.SETLISTFM_API_KEY,
    "Accept": "application/json",
}


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
    return [parse_candidate(s) for s in raw_list]


# 아티스트의 과거 공연 셋리스트를 여러 페이지에 걸쳐 가져옴
async def search_setlists_by_artist(artist_name: str, pages: int = 3) -> list[dict]:
    all_setlists = []
    for page in range(1, pages + 1):
        if page > 1:
            await asyncio.sleep(0.5)

        params = {"artistName": artist_name, "p": page}
        async with httpx.AsyncClient(timeout=10.0) as client:
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
        all_setlists.extend(setlists)

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
