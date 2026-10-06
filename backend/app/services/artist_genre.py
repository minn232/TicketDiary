import logging
from datetime import datetime, timedelta, timezone

from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import AsyncSessionLocal
from app.models.artist_genre import ArtistGenre
from app.models.artist_normalization import CanonicalArtist
from app.services.lastfm import GENRE_TAG_MAP
from app.services.musicbrainz import fetch_artist_genres_and_country

logger = logging.getLogger(__name__)

# MusicBrainz 장르명 중 Last.fm 화이트리스트에 없는 것들을 같은 라벨로 연결 (세부 장르는 상위 라벨로)
_MB_EXTRA_TAGS: dict[str, str] = {
    "j-rock": "록/밴드",
    "pop rock": "록/밴드",
    "alternative rock": "록/밴드",
    "hard rock": "록/밴드",
    "dance-pop": "일렉트로닉/댄스",
    "contemporary r&b": "알앤비/소울",
}
_MB_GENRE_MAP: dict[str, str] = {**GENRE_TAG_MAP, **_MB_EXTRA_TAGS}

# 아티스트당 라벨 상한 - 장르가 많이 붙는 아티스트가 결산 표를 여러 장르로 흩뜨리는 걸 막음
_MAX_MB_LABELS = 3

# MusicBrainz 장르를 이 기간이 지나면 다시 조회(조회 실패로 기록된 것도 같은 주기로 재시도)
_MB_GENRE_TTL = timedelta(days=90)


# MusicBrainz 장르 원문(득표 순)을 앱 장르 라벨로 변환 (중복 제거, 득표 순서 유지)
def resolve_mb_genres(raw_genres: list[str]) -> list[str]:
    labels: list[str] = []
    for name in raw_genres:
        label = _MB_GENRE_MAP.get(name.strip().lower())
        if label and label not in labels:
            labels.append(label)
    return labels[:_MAX_MB_LABELS]


# 아티스트 이름들의 장르 라벨. MusicBrainz(mbid로 확정된 아티스트)를 먼저 쓰고, 라벨이 안 나오는
# 아티스트만 Last.fm으로 보완 - Last.fm은 이름 검색이라 동명이인 태그가 섞이는 사례가 있었음
# (K-pop 그룹 CLOSE YOUR EYES가 같은 이름 메탈코어 밴드 태그로 분류됨)
async def get_artist_genres(db: AsyncSession, names: set[str]) -> dict[str, list[str]]:
    if not names:
        return {}

    result: dict[str, list[str]] = {}
    rows = await db.execute(
        select(CanonicalArtist.canonical_name, CanonicalArtist.display_name, CanonicalArtist.mb_genres).where(
            or_(CanonicalArtist.canonical_name.in_(names), CanonicalArtist.display_name.in_(names)),
            CanonicalArtist.mb_genres.isnot(None),
        )
    )
    for canonical_name, display_name, mb_genres in rows.all():
        labels = resolve_mb_genres(mb_genres)
        if not labels:
            continue
        for name in (canonical_name, display_name):
            if name in names:
                result[name] = labels

    remaining = names - result.keys()
    if remaining:
        lastfm_rows = await db.execute(
            select(ArtistGenre.artist_name, ArtistGenre.genres).where(
                ArtistGenre.artist_name.in_(remaining), ArtistGenre.genres.isnot(None)
            )
        )
        result.update(dict(lastfm_rows.all()))
    return result


# mbid가 있는 canonical의 MusicBrainz 장르/국가를 하루 limit명씩 채움. 정규화 배치와 같은 호출
# 제한기를 쓰므로(2초 간격) 정규화 직후 별도 시각에 돌려 서로 늦추지 않게 함. 조회 실패는
# mb_genres=NULL + 시각만 기록해 같은 날 반복 재시도를 막고 TTL 뒤에 다시 시도
async def sync_musicbrainz_genres(limit: int = 300) -> dict:
    stats = {"targets": 0, "fetched": 0, "no_genre": 0, "failed": 0}
    stale_cutoff = datetime.now(timezone.utc) - _MB_GENRE_TTL
    async with AsyncSessionLocal() as db:
        rows = await db.execute(
            select(CanonicalArtist)
            .where(
                CanonicalArtist.mbid.isnot(None),
                or_(
                    CanonicalArtist.mb_genres_fetched_at.is_(None),
                    CanonicalArtist.mb_genres_fetched_at < stale_cutoff,
                ),
            )
            .order_by(CanonicalArtist.mb_genres_fetched_at.asc().nullsfirst())
            .limit(limit)
        )
        artists = list(rows.scalars().all())
        stats["targets"] = len(artists)

        for i, artist in enumerate(artists, 1):
            detail = await fetch_artist_genres_and_country(artist.mbid)
            artist.mb_genres_fetched_at = datetime.now(timezone.utc)
            if detail is None:
                artist.mb_genres = None
                stats["failed"] += 1
            else:
                artist.mb_genres = detail["genres"]
                artist.mb_country = detail["country"]
                stats["fetched" if detail["genres"] else "no_genre"] += 1
            if i % 20 == 0:
                await db.commit()
        await db.commit()

    logger.info(f"[MB] 장르/국가 동기화 완료: {stats}")
    return stats
