import asyncio
import logging
import random
import time
import re
from itertools import zip_longest
from datetime import date, datetime, timedelta, timezone
from uuid import UUID

import httpx
from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import AsyncSessionLocal
from app.models.concert import Concert
from app.models.itunes_catalog_cache import ItunesCatalogCache
from app.models.setlist import PreSetlist, RealSetlist
from app.models.ticket import Ticket
from app.services.lineup import get_lineup_artists_for_date
from app.services.representative_songs import (
    ITUNES_COUNTRY,
    ITUNES_LOOKUP_URL,
    is_alt_version,
    lookup_in_title_store,
    _title_key,
    resolve_itunes_artist_id_for,
)
from app.services.setlist import resolve_performance_date

logger = logging.getLogger(__name__)

_CATALOG_TTL = timedelta(days=7)
# 페스티벌은 아티스트가 많아서 iTunes 조회가 폭증하지 않게 공연당 상한(넘으면 열 때마다 무작위로 골라 다양하게)
_MAX_ARTISTS = 8
# 아티스트가 _MAX_ARTISTS보다 많은 공연(페스티벌)은 더 많은 팀을 담되 팀당 곡 수를 줄여 다양하게 들려줌
_FESTIVAL_MAX_ARTISTS = 12
_FESTIVAL_TRACKS_PER_ARTIST = 2
# 곡 목록이 있는 아티스트 _MAX_ARTISTS명을 채우려고 시도할 최대 아티스트 수(iTunes ID 없는 아티스트는 건너뜀)
_MAX_ARTIST_ATTEMPTS = 20
# 곡 목록이 하나라도 모였으면 이 시간 넘어서는 더 모으지 않고 응답
_MAX_COLLECT_SECONDS = 12.0
_MAX_TRACKS = 30
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
                ITUNES_LOOKUP_URL,
                params={"id": itunes_artist_id, "entity": "song", "limit": 200, "country": ITUNES_COUNTRY},
            )
            response.raise_for_status()
            # 피처링으로만 참여한 남의 곡도 같이 오므로 아티스트 ID가 같은 곡만 씀
            tracks = [
                r for r in response.json().get("results", [])
                if r.get("wrapperType") == "track" and str(r.get("artistId")) == itunes_artist_id
                and r.get("trackId") and r.get("trackName") and r.get("previewUrl")
            ]
            titled, _ = await lookup_in_title_store(client, [r["trackId"] for r in tracks])
    except (httpx.HTTPError, ValueError) as e:
        logger.warning(f"iTunes 미리듣기 곡 목록 조회 실패 (artist_id={itunes_artist_id}): {e}")
        return None

    result = []
    seen: set[str] = set()
    for r in tracks:
        kr_name = (titled.get(r["trackId"]) or r).get("trackName") or r["trackName"]
        key = _title_key(kr_name)
        if not key or key in seen or is_alt_version(kr_name) or is_alt_version(r["trackName"]):
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
# max_artists를 주면 곡 목록이 있는 아티스트가 그만큼 모이는 즉시 응답(첫 재생을 빨리 시작하려는 빠른 조회)
async def get_preview_tracks(
    db: AsyncSession, concert_id: UUID, explicit_date: date | None = None, max_artists: int = _MAX_ARTISTS
) -> dict:
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
        random.shuffle(artists)

    # 앞에서부터 곡 목록이 있는 아티스트를 _MAX_ARTISTS명까지 채움(ID 없는 아티스트가 자리를 먹지 않게).
    # 페스티벌처럼 아티스트가 많으면 ID 미확정 아티스트의 iTunes 자동 검색은 건너뜀 - 검색 한 번씩이
    # 쌓여 응답이 수 분 걸림(미확정 아티스트는 밤 미리 받기 배치가 확정해 둠)
    is_festival = len(artists) > _MAX_ARTISTS
    allow_search = not is_festival
    if is_festival and max_artists == _MAX_ARTISTS:
        max_artists = _FESTIVAL_MAX_ARTISTS  # 빠른 조회(max_artists 지정)는 그대로 둠
    started = time.monotonic()
    catalogs: dict[str, list[dict]] = {}
    for artist in artists[:_MAX_ARTIST_ATTEMPTS]:
        if len(catalogs) >= max_artists or (catalogs and time.monotonic() - started > _MAX_COLLECT_SECONDS):
            break
        itunes_artist_id = await resolve_itunes_artist_id_for(db, artist, concert_id, allow_search)
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

    # 아티스트별로 real → pre → 대표곡 순으로 따로 채움 - 셋리가 일부 아티스트 것만 있는 페스티벌에서
    # 셋리 있는 한 팀 곡만 나오지 않게 함. 응답 source는 쓰인 것 중 가장 앞선 출처
    collected: list[dict] = []
    used_sources: list[str] = []
    for artist, artist_catalog in catalogs.items():
        for source, songs in sources:
            matched = _match_songs(songs, {artist: artist_catalog})
            if matched:
                collected.extend(matched)
                used_sources.append(source)
                break
        else:
            collected.extend(_to_track(t, artist) for t in artist_catalog[:_CATALOG_FALLBACK_TRACKS])
            used_sources.append("catalog")
    if is_festival:
        counts: dict[str, int] = {}
        limited = []
        for track in collected:
            counts[track["artist_name"]] = counts.get(track["artist_name"], 0) + 1
            if counts[track["artist_name"]] <= _FESTIVAL_TRACKS_PER_ARTIST:
                limited.append(track)
        collected = limited
    source = next(name for name in ("real", "pre", "catalog") if name in used_sources)
    return {"source": source, "tracks": _interleave(collected, _MAX_TRACKS)}


# 미리듣기 곡 목록 미리 데우기 - 티켓이 있는 공연의 아티스트 곡 목록을 밤에 캐시해 둬서 유저가 처음 눌러도
# iTunes를 기다리지 않게 함. iTunes는 비공식 호출 제한(대략 분당 20회)이 있어 간격을 두고 한 번에
# 처리하는 아티스트 수에도 상한을 둠(캐시 TTL이 7일이라 매일 돌려도 7일에 한 번씩만 다시 받음)
_WARM_INTERVAL_SECONDS = 4.0
_WARM_MAX_ARTISTS_PER_RUN = 80
_WARM_MAX_CONSECUTIVE_FAILURES = 3
# 공연 끝난 지 이 기간 안의 티켓까지 대상(공연 후 페이지에서도 재생하므로)
_WARM_AFTER_CONCERT = timedelta(days=30)


async def _is_catalog_fresh(db: AsyncSession, itunes_artist_id: str) -> bool:
    row = (await db.execute(
        select(ItunesCatalogCache).where(ItunesCatalogCache.itunes_artist_id == itunes_artist_id)
    )).scalar_one_or_none()
    return row is not None and datetime.now(timezone.utc) - row.fetched_at < _CATALOG_TTL


async def warm_preview_catalogs(interval: float = _WARM_INTERVAL_SECONDS) -> dict:
    now = datetime.now(timezone.utc)
    stats = {"artists": 0, "fetched": 0, "skipped_fresh": 0, "no_itunes_id": 0, "failed": 0}
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(
            select(Concert.id, Concert.artist_name)
            .join(Ticket, Ticket.concert_id == Concert.id)
            .where(Concert.end_date >= now - _WARM_AFTER_CONCERT)
            .group_by(Concert.id, Concert.artist_name, Concert.start_date)
            .order_by(Concert.start_date)
        )).all()

        targets: list[tuple[str, UUID]] = []
        seen: set[str] = set()
        for concert_id, artist_names in rows:
            for artist in artist_names or []:
                if artist not in seen:
                    seen.add(artist)
                    targets.append((artist, concert_id))

        consecutive_failures = 0
        for artist, concert_id in targets:
            if stats["artists"] >= _WARM_MAX_ARTISTS_PER_RUN:
                break
            itunes_artist_id = await resolve_itunes_artist_id_for(db, artist, concert_id)
            if itunes_artist_id is None:
                stats["no_itunes_id"] += 1
                stats["artists"] += 1
                await asyncio.sleep(interval)  # 아티스트 검색 호출이 있었을 수 있음
                continue
            if await _is_catalog_fresh(db, itunes_artist_id):
                stats["skipped_fresh"] += 1
                continue
            stats["artists"] += 1
            await _get_catalog(db, itunes_artist_id)
            if await _is_catalog_fresh(db, itunes_artist_id):
                stats["fetched"] += 1
                consecutive_failures = 0
            else:
                stats["failed"] += 1
                consecutive_failures += 1
                if consecutive_failures >= _WARM_MAX_CONSECUTIVE_FAILURES:
                    # iTunes가 막혔거나 장애 - 계속 두드리면 다른 기능까지 막힐 수 있어 중단
                    logger.warning("미리듣기 곡 목록 미리 받기 연속 실패, 중단")
                    break
            await asyncio.sleep(interval)
    return stats
