import uuid
from datetime import datetime, timezone
from unittest.mock import AsyncMock, patch

import pytest
from sqlalchemy import select

from app.core.database import AsyncSessionLocal
from app.models.artist_genre import ArtistGenre
from app.models.artist_normalization import CanonicalArtist
from app.services.artist_genre import get_artist_genres, resolve_mb_genres, sync_musicbrainz_genres
from app.services.kopis import _parse_yes_no


def _name(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:8]}"


# MusicBrainz 장르명이 앱 라벨로 매핑되고(J-pop 포함), 득표 순서 유지 + 중복 제거 + 3개 상한
def test_resolve_mb_genres_maps_dedups_and_caps():
    assert resolve_mb_genres(["j-pop", "pop", "j-rock", "rock"]) == ["J-pop", "팝", "록/밴드"]
    assert resolve_mb_genres(["alternative rock", "rock"]) == ["록/밴드"]
    assert resolve_mb_genres(["yakousei", "unknown tag"]) == []


@pytest.mark.parametrize("raw,expected", [("Y", True), ("N", False), (" y ", True), ("", None), (None, None), ("?", None)])
def test_parse_yes_no(raw, expected):
    assert _parse_yes_no(raw) is expected


# MusicBrainz 장르가 라벨로 나오면 Last.fm 값보다 우선(동명이인 태그가 섞이는 Last.fm 오류 방지)
@pytest.mark.asyncio
async def test_get_artist_genres_prefers_musicbrainz_over_lastfm():
    name = _name("mbfirst")
    async with AsyncSessionLocal() as db:
        db.add(CanonicalArtist(canonical_name=name, mbid=str(uuid.uuid4()), mb_genres=["k-pop"]))
        db.add(ArtistGenre(artist_name=name, genres=["메탈"]))
        await db.commit()

        result = await get_artist_genres(db, {name})
    assert result[name] == ["K-pop"]


# MusicBrainz에 장르가 없거나 라벨로 못 바꾸면 Last.fm으로 보완, 둘 다 없으면 결과에서 빠짐
@pytest.mark.asyncio
async def test_get_artist_genres_falls_back_to_lastfm_and_omits_unknown():
    empty_mb, no_data = _name("emptymb"), _name("nodata")
    async with AsyncSessionLocal() as db:
        db.add(CanonicalArtist(canonical_name=empty_mb, mbid=str(uuid.uuid4()), mb_genres=["yakousei"]))
        db.add(ArtistGenre(artist_name=empty_mb, genres=["힙합"]))
        await db.commit()

        result = await get_artist_genres(db, {empty_mb, no_data})
    assert result == {empty_mb: ["힙합"]}


# display_name으로 들어온 이름도 canonical을 찾아 매칭
@pytest.mark.asyncio
async def test_get_artist_genres_matches_display_name():
    canonical, display = _name("canon"), _name("disp")
    async with AsyncSessionLocal() as db:
        db.add(CanonicalArtist(canonical_name=canonical, display_name=display, mbid=str(uuid.uuid4()), mb_genres=["trot"]))
        await db.commit()

        result = await get_artist_genres(db, {display})
    assert result == {display: ["트로트"]}


# 동기화: 장르 있음/없음/조회 실패를 구분해 기록하고, 조회 완료된 건 다시 대상이 되지 않음
@pytest.mark.asyncio
async def test_sync_musicbrainz_genres_records_each_outcome():
    ok, empty, bad = _name("ok"), _name("empty"), _name("bad")
    mbids = {ok: str(uuid.uuid4()), empty: str(uuid.uuid4()), bad: str(uuid.uuid4())}
    async with AsyncSessionLocal() as db:
        for n, m in mbids.items():
            db.add(CanonicalArtist(canonical_name=n, mbid=m))
        await db.commit()

    async def fake_fetch(mbid):
        if mbid == mbids[ok]:
            return {"genres": ["j-pop"], "country": "JP"}
        if mbid == mbids[empty]:
            return {"genres": [], "country": "KR"}
        return None

    with patch("app.services.artist_genre.fetch_artist_genres_and_country", new=AsyncMock(side_effect=fake_fetch)):
        await sync_musicbrainz_genres(limit=1000)
        second = await sync_musicbrainz_genres(limit=1000)

    async with AsyncSessionLocal() as db:
        rows = {
            r.canonical_name: r
            for r in (await db.execute(select(CanonicalArtist).where(CanonicalArtist.canonical_name.in_(mbids)))).scalars()
        }
    assert rows[ok].mb_genres == ["j-pop"] and rows[ok].mb_country == "JP"
    assert rows[empty].mb_genres == [] and rows[empty].mb_genres_fetched_at is not None
    assert rows[bad].mb_genres is None and rows[bad].mb_genres_fetched_at is not None
    assert second["targets"] == 0
