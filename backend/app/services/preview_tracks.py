import logging
import random
import re
from itertools import zip_longest
from datetime import date, datetime, timedelta, timezone
from uuid import UUID

import httpx
from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.concert import Concert
from app.models.itunes_catalog_cache import ItunesCatalogCache
from app.models.setlist import PreSetlist, RealSetlist
from app.services.lineup import get_lineup_artists_for_date
from app.services.representative_songs import (
    _ITUNES_COUNTRY,
    _ITUNES_LOOKUP_URL,
    _is_alt_version,
    _lookup_in_title_store,
    _title_key,
    resolve_itunes_artist_id_for,
)
from app.services.setlist import resolve_performance_date

logger = logging.getLogger(__name__)

_CATALOG_TTL = timedelta(days=7)
# 페스티벌은 아티스트가 많아서 iTunes 조회가 폭증하지 않게 공연당 상한(넘으면 열 때마다 무작위로 골라 다양하게)
_MAX_ARTISTS = 5
_MAX_TRACKS = 20
_CATALOG_FALLBACK_TRACKS = 10

# "(feat. ...)" / "[feat. ...]" / "(with ...)" 표기 차이 제거용
_FEAT_SUFFIX = re.compile(r"\s*[\(\[]\s*(?:feat|ft|featuring|with)\b[^\)\]]*[\)\]]", re.IGNORECASE)


def _keys(title: str) -> set[str]:
    return {k for k in (_title_key(title), _title_key(_FEAT_SUFFIX.sub("", title))) if k}


# iTunes 곡 목록(미리듣기 URL 포함) - 셋리 곡 매칭과 대표곡 폴백 양쪽에 씀. 실패 시 None
# (호출부가 캐싱하지 않게 "곡 없음"인 빈 리스트와 구분)
async def _fetch_catalog(itunes_artist_id: str) -> list[dict] | None:
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.get(
                _ITUNES_LOOKUP_URL,
                params={"id": itunes_artist_id, "entity": "song", "limit": 200, "country": _ITUNES_COUNTRY},
            )
            response.raise_for_status()
            # 피처링으로만 참여한 남의 곡도 같이 오므로 아티스트 ID가 같은 곡만 씀
            tracks = [
                r for r in response.json().get("results", [])
                if r.get("wrapperType") == "track" and str(r.get("artistId")) == itunes_artist_id
                and r.get("trackId") and r.get("trackName") and r.get("previewUrl")
            ]
            titled, _ = await _lookup_in_title_store(client, [r["trackId"] for r in tracks])
    except (httpx.HTTPError, ValueError) as e:
        logger.warning(f"iTunes 미리듣기 곡 목록 조회 실패 (artist_id={itunes_artist_id}): {e}")
        return None

    result = []
    seen: set[str] = set()
    for r in tracks:
        kr_name = (titled.get(r["trackId"]) or r).get("trackName") or r["trackName"]
        key = _title_key(kr_name)
        if not key or key in seen or _is_alt_version(kr_name) or _is_alt_version(r["trackName"]):
            continue
        seen.add(key)
        result.append({
            "track_id": r["trackId"],
            "us_name": r["trackName"],
            "kr_name": kr_name,
            "preview_url": r["previewUrl"],
            "track_view_url": r.get("trackViewUrl"),
        })
    return result


async def _get_catalog(db: AsyncSession, itunes_artist_id: str) -> list[dict]:
    row = (await db.execute(
        select(ItunesCatalogCache).where(ItunesCatalogCache.itunes_artist_id == itunes_artist_id)
    )).scalar_one_or_none()
    now = datetime.now(timezone.utc)
    if row is not None and now - row.fetched_at < _CATALOG_TTL:
        return row.tracks

    tracks = await _fetch_catalog(itunes_artist_id)
    if tracks is None:
        # 실패했으면 낡은 캐시라도 씀(없으면 그 아티스트만 빠짐)
        return row.tracks if row is not None else []
    # 같은 아티스트 티켓을 동시에 처음 열면 둘 다 row=None이라 둘 다 넣으려 해서 upsert로 저장
    await db.execute(
        pg_insert(ItunesCatalogCache)
        .values(itunes_artist_id=itunes_artist_id, tracks=tracks, fetched_at=now)
        .on_conflict_do_update(
            index_elements=["itunes_artist_id"], set_={"tracks": tracks, "fetched_at": now}
        )
    )
    await db.commit()
    return tracks


# 아티스트별로 번갈아 한 곡씩 뽑아 limit까지 - 페스티벌에서 앞 아티스트 곡만 나오지 않게 함
def _interleave(tracks: list[dict], limit: int) -> list[dict]:
    groups: dict[str, list[dict]] = {}
    for track in tracks:
        groups.setdefault(track["artist_name"], []).append(track)
    result = []
    for round_tracks in zip_longest(*groups.values()):
        result.extend(t for t in round_tracks if t is not None)
    return result[:limit]


def _to_track(track: dict, artist_name: str) -> dict:
    return {
        "track_name": track["kr_name"],
        "artist_name": artist_name,
        "preview_url": track["preview_url"],
        "track_view_url": track.get("track_view_url"),
    }


# 셋리 곡 이름을 그 아티스트 곡 목록과 제목 키로 정확히 맞춤 - 자유 검색은 다른 곡이 걸려서 안 씀
def _match_songs(songs: list[dict], catalogs: dict[str, list[dict]]) -> list[dict]:
    index: dict[str, dict[str, dict]] = {}
    for artist, tracks in catalogs.items():
        by_key = index.setdefault(artist, {})
        for track in tracks:
            for name in (track["kr_name"], track["us_name"]):
                for key in _keys(name):
                    by_key.setdefault(key, track)

    matched, used = [], set()
    for song in songs:
        # 페스티벌 곡은 그 아티스트 곡 목록에서만, 아티스트 표시가 없으면 전체 목록에서
        artist = song.get("artist")
        if artist in catalogs:
            candidates = [artist]
        elif not artist:
            candidates = list(catalogs)
        else:
            continue
        for candidate in candidates:
            track = next((index[candidate][k] for k in _keys(song.get("name", "")) if k in index[candidate]), None)
            if track is not None and track["track_id"] not in used:
                used.add(track["track_id"])
                matched.append(_to_track(track, candidate))
                break
    return matched


async def _read_setlist_songs(db: AsyncSession, model, *conditions) -> list[dict]:
    row = (await db.execute(select(model).where(*conditions))).scalars().first()
    return list(row.songs) if row is not None and row.songs else []


# 티켓 미리듣기 후보 곡 - real(그 날 실제 셋리) → pre(예상 셋리) → catalog(아티스트 대표곡) 순으로
# 곡이 1개라도 나오면 멈춤. 셋리는 읽기만 함(get_*_setlist는 조회하며 생성/저장할 수 있어서 안 씀)
async def get_preview_tracks(db: AsyncSession, concert_id: UUID, explicit_date: date | None = None) -> dict:
    concert = await db.get(Concert, concert_id)
    if concert is None:
        return {"source": None, "tracks": []}
    try:
        performance_date = resolve_performance_date(concert, explicit_date)
    except HTTPException:
        # 날짜를 특정 못 하는 다일 공연 - 실제 셋리는 건너뛰고 예상/대표곡만 씀
        performance_date = None

    artists = list(concert.artist_name or [])
    if performance_date is not None:
        artists = await get_lineup_artists_for_date(db, concert_id, performance_date) or artists
    if len(artists) > _MAX_ARTISTS:
        artists = random.sample(artists, _MAX_ARTISTS)

    catalogs: dict[str, list[dict]] = {}
    for artist in artists:
        itunes_artist_id = await resolve_itunes_artist_id_for(db, artist, concert_id)
        if itunes_artist_id is None:
            continue
        tracks = await _get_catalog(db, itunes_artist_id)
        if tracks:
            catalogs[artist] = tracks
    if not catalogs:
        return {"source": None, "tracks": []}

    sources: list[tuple[str, list[dict]]] = []
    if performance_date is not None:
        sources.append(("real", await _read_setlist_songs(
            db, RealSetlist, RealSetlist.concert_id == concert_id, RealSetlist.performance_date == performance_date,
        )))
    sources.append(("pre", await _read_setlist_songs(db, PreSetlist, PreSetlist.concert_id == concert_id)))
    for source, songs in sources:
        matched = _match_songs(songs, catalogs)
        if matched:
            return {"source": source, "tracks": _interleave(matched, _MAX_TRACKS)}

    fallback = [
        _to_track(track, artist)
        for artist, tracks in catalogs.items()
        for track in tracks[:_CATALOG_FALLBACK_TRACKS]
    ]
    return {"source": "catalog", "tracks": _interleave(fallback, _MAX_TRACKS)}
