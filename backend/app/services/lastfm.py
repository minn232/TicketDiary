import asyncio
import logging
from datetime import datetime, timedelta, timezone

import httpx
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.database import AsyncSessionLocal
from app.models.artist_similarity import ArtistSimilarity
from app.models.artist_genre import ArtistGenre
from app.models.artist_lastfm_sync_status import ArtistLastfmSyncStatus
from app.models.concert import Concert

logger = logging.getLogger(__name__)

# Last.fm 요청 간 최소 간격 (레이트리밋 방지)
_REQUEST_INTERVAL = 0.3

# Last.fm이 빈 결과를 준(=못 찾음) 아티스트 재시도 쿨다운/상한 - 없으면 매일 밤 똑같이 실패하는
# 이름을 영원히 재시도하게 됨(실측 1800~2270건 누적). crawl_attempted_at류와 같은 취지지만
# 포스터/크롤링과 달리 Last.fm 카탈로그가 나중에 갱신될 수도 있어 쿨다운을 길게(1주) 잡음
_LASTFM_RETRY_COOLDOWN = timedelta(days=7)
_MAX_LASTFM_ATTEMPTS = 5


# names 중 아직 Last.fm 재시도가 허용되는 것만 골라 반환(순서 유지) - 실패 기록이 없거나,
# 쿨다운이 지났고 상한 미만이면 허용. sync_type별로 따로 추적(같은 아티스트라도 유사아티스트/
# 장르 중 한쪽만 실패할 수 있음)
async def _filter_lastfm_retry_eligible(names: list[str], sync_type: str) -> list[str]:
    if not names:
        return []

    cutoff = datetime.now(timezone.utc) - _LASTFM_RETRY_COOLDOWN
    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(ArtistLastfmSyncStatus).where(
                ArtistLastfmSyncStatus.sync_type == sync_type,
                ArtistLastfmSyncStatus.artist_name.in_(names),
            )
        )
        status_by_name = {row.artist_name: row for row in result.scalars().all()}

    return [
        name
        for name in names
        if (status := status_by_name.get(name)) is None
        or (status.attempt_count < _MAX_LASTFM_ATTEMPTS and status.last_attempted_at < cutoff)
    ]


# 실패(빈 결과) 기록 - 있으면 attempt_count/시각 갱신, 없으면 새로 생성
async def _record_lastfm_failure(artist_name: str, sync_type: str) -> None:
    now = datetime.now(timezone.utc)
    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(ArtistLastfmSyncStatus).where(
                ArtistLastfmSyncStatus.artist_name == artist_name,
                ArtistLastfmSyncStatus.sync_type == sync_type,
            )
        )
        row = result.scalar_one_or_none()
        if row is None:
            db.add(
                ArtistLastfmSyncStatus(
                    artist_name=artist_name, sync_type=sync_type, last_attempted_at=now, attempt_count=1
                )
            )
        else:
            row.last_attempted_at = now
            row.attempt_count += 1
        await db.commit()


# 성공(결과 확보)하면 그동안 쌓인 실패 기록은 지움 - 재시도 상한과 무관하게 다음에 또 실패하면
# 새로 카운트 시작(과거 실패 이력을 계속 끌고 다닐 이유 없음)
async def _clear_lastfm_failure(db: AsyncSession, artist_name: str, sync_type: str) -> None:
    await db.execute(
        delete(ArtistLastfmSyncStatus).where(
            ArtistLastfmSyncStatus.artist_name == artist_name,
            ArtistLastfmSyncStatus.sync_type == sync_type,
        )
    )

# Last.fm 태그(자유 텍스트, 소문자 기준)를 결산에 보여줄 장르 라벨로 정규화하는 화이트리스트.
# "seen live"/"female vocalists"/아티스트 이름 자체 같은 비-장르 태그가 섞여 들어오는 걸 막기 위해,
# getTopTags가 이미 커뮤니티 가중치(count) 내림차순으로 준 순서를 그대로 믿고 훑다가 이 목록에
# 처음 걸리는 태그의 라벨을 채택한다(=Last.fm 순위 + 화이트리스트 교집합의 상위 1개).
_GENRE_TAG_MAP: dict[str, str] = {
    tag: label
    for label, tags in {
        "K-pop": ["k-pop", "kpop"],
        "발라드": ["ballad"],
        "힙합": ["hip hop", "hip-hop", "rap"],
        "알앤비/소울": ["r&b", "rnb", "soul"],
        "록/밴드": ["rock", "indie rock", "band"],
        "인디": ["indie", "indie pop", "indie folk"],
        "일렉트로닉/댄스": ["electronic", "edm", "dance", "house"],
        "트로트": ["trot"],
        "포크/어쿠스틱": ["folk", "acoustic", "singer-songwriter"],
        "재즈": ["jazz"],
        "메탈": ["metal", "heavy metal", "metalcore"],
        "펑크": ["punk", "punk rock"],
        "시티팝": ["city pop", "citypop"],
        "팝": ["pop"],
    }.items()
    for tag in tags
}


# Last.fm 태그 목록(이미 count 내림차순)에서 화이트리스트에 걸리는 라벨을 전부(중복 제거,
# Last.fm 순위 순서 유지) 반환. 아티스트 하나가 여러 장르에 걸리는 게 자연스러워서(예: 힙합+K-pop)
# 첫 매칭 하나만 취하지 않음. 하나도 안 걸리면 빈 리스트(= "태그는 있지만 분류 가능한 장르가 없음")
def resolve_genres(tags: list[str]) -> list[str]:
    matched: list[str] = []
    seen: set[str] = set()
    for tag in tags:
        label = _GENRE_TAG_MAP.get(tag.strip().lower())
        if label and label not in seen:
            seen.add(label)
            matched.append(label)
    return matched


# Last.fm artist.getSimilar 호출 (autocorrect로 표기 오차 보정). 실패/결과없음이면 빈 리스트
async def fetch_similar_artists(artist_name: str, limit: int = 30) -> list[tuple[str, float]]:
    if not settings.LASTFM_API_KEY:
        return []

    params = {
        "method": "artist.getSimilar",
        "artist": artist_name,
        "api_key": settings.LASTFM_API_KEY,
        "autocorrect": 1,
        "limit": limit,
        "format": "json",
    }

    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.get(settings.LASTFM_BASE_URL, params=params)
    except httpx.HTTPError as e:
        logger.warning(f"Last.fm 호출 실패 ({artist_name}): {e}")
        return []

    if response.status_code != 200:
        logger.warning(f"Last.fm 응답 오류 ({artist_name}): {response.status_code}")
        return []

    try:
        payload = response.json()
    except ValueError as e:
        logger.warning(f"Last.fm 응답 파싱 실패 ({artist_name}): {e}")
        return []

    artists = payload.get("similarartists", {}).get("artist", [])
    return [(a["name"], float(a.get("match", 0))) for a in artists if a.get("name")]


# Last.fm artist.getTopTags 호출 (autocorrect로 표기 오차 보정). count 내림차순으로 정렬해 반환.
# 실패/결과없음/API 키 없음이면 빈 리스트
async def fetch_top_tags(artist_name: str) -> list[str]:
    if not settings.LASTFM_API_KEY:
        return []

    params = {
        "method": "artist.gettoptags",
        "artist": artist_name,
        "api_key": settings.LASTFM_API_KEY,
        "autocorrect": 1,
        "format": "json",
    }

    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.get(settings.LASTFM_BASE_URL, params=params)
    except httpx.HTTPError as e:
        logger.warning(f"Last.fm 태그 조회 실패 ({artist_name}): {e}")
        return []

    if response.status_code != 200:
        logger.warning(f"Last.fm 태그 응답 오류 ({artist_name}): {response.status_code}")
        return []

    try:
        payload = response.json()
    except ValueError as e:
        logger.warning(f"Last.fm 태그 응답 파싱 실패 ({artist_name}): {e}")
        return []

    tags = payload.get("toptags", {}).get("tag", [])
    tags_sorted = sorted(tags, key=lambda t: int(t.get("count", 0)), reverse=True)
    return [t["name"] for t in tags_sorted if t.get("name")]


# 아티스트 한 명의 Last.fm 태그를 가져와 화이트리스트로 정규화한 장르를 캐싱.
# 태그 자체를 못 받아오면(API 키 없음/호출 실패/Last.fm에 없는 이름) 실패로 기록해 쿨다운
# 재시도가 걸리게 하고 조용히 리턴 - 안 그러면 매 배치/이벤트마다 똑같이 재시도됨
async def _fetch_and_cache_artist_genre(artist_name: str) -> None:
    tags = await fetch_top_tags(artist_name)
    if not tags:
        await _record_lastfm_failure(artist_name, "genre")
        return

    async with AsyncSessionLocal() as db:
        db.add(ArtistGenre(artist_name=artist_name, genres=resolve_genres(tags) or None))
        await _clear_lastfm_failure(db, artist_name, "genre")
        await db.commit()


# 아직 캐싱 안 된 아티스트만 Last.fm 태그를 가져와 화이트리스트로 정규화한 장르로 저장
# (genres=None도 "확인했지만 태그 없었음"으로 캐싱해 재조회 안 함).
# "안전망" 역할 - 실제론 티켓 등록 시점에 ensure_artist_genres_cached가 즉시 캐싱해서
# 평소 처리 대상이 거의 없어야 정상. 즉시 캐싱 실패/로직 붙기 전 오래된 티켓 뒤처리용.
async def sync_artist_genres() -> None:
    async with AsyncSessionLocal() as db:
        concert_result = await db.execute(select(Concert.artist_name).where(Concert.artist_name != []))
        all_names = {
            name.strip()
            for arr in concert_result.scalars().all()
            for name in (arr or [])
            if name and name.strip()
        }

        cached_result = await db.execute(select(ArtistGenre.artist_name))
        cached_names = set(cached_result.scalars().all())

    pending = sorted(all_names - cached_names)
    pending = await _filter_lastfm_retry_eligible(pending, "genre")
    if not pending:
        logger.info("Last.fm 신규 장르 캐싱 대상 아티스트 없음")
        return

    logger.info(f"Last.fm 장르 캐싱 대상 {len(pending)}건")
    for i, artist_name in enumerate(pending):
        if i > 0:
            await asyncio.sleep(_REQUEST_INTERVAL)

        try:
            await _fetch_and_cache_artist_genre(artist_name)
        except Exception as e:
            logger.warning(f"Last.fm 장르 캐싱 실패, 다음으로 계속 ({artist_name}): {e}")
            continue


# 티켓 등록 등 이벤트 발생 시 그 자리에서(배치를 기다리지 않고) 바로 캐싱.
# Last.fm ToS(초당 5회, 5분 평균) 대비 사람이 티켓을 등록하는 빈도는 무시할 만한 수준이라 문제
# 없음. 인자로 받은 아티스트 중 이미 캐싱된 건 건너뛰므로 매 호출이 가볍다(대개 0~1명).
async def ensure_artist_genres_cached(artist_names: list[str]) -> None:
    names = {name.strip() for name in artist_names if name and name.strip()}
    if not names:
        return

    async with AsyncSessionLocal() as db:
        cached_result = await db.execute(
            select(ArtistGenre.artist_name).where(ArtistGenre.artist_name.in_(names))
        )
        cached_names = set(cached_result.scalars().all())

    pending = sorted(names - cached_names)
    pending = await _filter_lastfm_retry_eligible(pending, "genre")
    for i, artist_name in enumerate(pending):
        if i > 0:
            await asyncio.sleep(_REQUEST_INTERVAL)

        try:
            await _fetch_and_cache_artist_genre(artist_name)
        except Exception as e:
            logger.warning(f"Last.fm 장르 즉시 캐싱 실패, 다음으로 계속 ({artist_name}): {e}")
            continue


# 아직 캐싱 안 된 아티스트만 골라 Last.fm에서 유사 아티스트를 가져와 저장
# (한 번 캐싱된 아티스트는 재조회하지 않음 - 유사 아티스트 관계는 자주 바뀌지 않는다고 가정)
async def sync_artist_similarities() -> None:
    async with AsyncSessionLocal() as db:
        concert_result = await db.execute(select(Concert.artist_name).where(Concert.artist_name != []))
        all_names = {
            name.strip()
            for arr in concert_result.scalars().all()
            for name in (arr or [])
            if name and name.strip()
        }

        cached_result = await db.execute(select(ArtistSimilarity.artist_name.distinct()))
        cached_names = set(cached_result.scalars().all())

    pending = sorted(all_names - cached_names)
    pending = await _filter_lastfm_retry_eligible(pending, "similarity")
    if not pending:
        logger.info("Last.fm 신규 캐싱 대상 아티스트 없음")
        return

    logger.info(f"Last.fm 유사 아티스트 캐싱 대상 {len(pending)}건")
    for i, artist_name in enumerate(pending):
        if i > 0:
            await asyncio.sleep(_REQUEST_INTERVAL)

        # 한 아티스트에서 예기치 못한 오류(DB 오류 등)가 나도 이후 아티스트들은 계속 처리
        # (안 그러면 이 아티스트가 pending 목록에서 매번 같은 자리에 있어 뒤쪽이 영구히 밀림)
        try:
            similar = await fetch_similar_artists(artist_name)
            if not similar:
                await _record_lastfm_failure(artist_name, "similarity")
                continue

            async with AsyncSessionLocal() as db:
                await db.execute(delete(ArtistSimilarity).where(ArtistSimilarity.artist_name == artist_name))
                db.add_all(
                    [
                        ArtistSimilarity(artist_name=artist_name, similar_artist_name=name, match_score=score)
                        for name, score in similar
                    ]
                )
                await _clear_lastfm_failure(db, artist_name, "similarity")
                await db.commit()
        except Exception as e:
            logger.warning(f"Last.fm 아티스트 캐싱 실패, 다음으로 계속 ({artist_name}): {e}")
            continue
