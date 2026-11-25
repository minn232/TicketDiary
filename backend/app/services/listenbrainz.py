import asyncio
import logging
from datetime import datetime, timezone

import httpx
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import AsyncSessionLocal
from app.models.artist_normalization import ArtistAlias, CanonicalArtist
from app.models.artist_similarity import ArtistSimilarity
from app.models.concert import Concert
# 캐시 TTL/하루 상한/실패 재시도 규칙은 Last.fm 때 것을 그대로 씀(실패 기록 테이블도 공용)
from app.services.lastfm import (
    _LASTFM_CACHE_TTL,
    _MAX_LASTFM_SYNC_PER_RUN,
    _clear_lastfm_failure,
    _filter_lastfm_retry_eligible,
    _record_lastfm_failure,
)

logger = logging.getLogger(__name__)

# 토큰 없이 열려 있는 실험용(labs) 주소라 응답 형태나 algorithm 값이 예고 없이 바뀔 수 있음
_SIMILAR_ARTISTS_URL = "https://labs.api.listenbrainz.org/similar-artists/json"
_ALGORITHM = "session_based_days_9000_session_300_contribution_5_threshold_15_limit_50_skip_30"
# 응답 헤더의 제한(10초에 30회)을 넘지 않는 간격
_REQUEST_INTERVAL = 1.1
# 연속으로 이만큼 호출이 실패하면 서비스 장애로 보고 그날 배치를 중단
_MAX_CONSECUTIVE_ERRORS = 5
# Last.fm 때의 "similarity" 실패 기록(쿨다운)이 새 조회를 막지 않게 구분값을 분리
_SYNC_TYPE = "lb_similarity"


# mbid의 유사 아티스트 [(mbid, 이름, 원점수)] - 결과가 없으면 빈 리스트, 호출 자체가 실패하면 None
# (호출 실패를 "결과 없음"으로 기록하면 장애 때 전원에게 쿨다운이 걸림)
async def fetch_similar_artists(mbid: str) -> list[tuple[str, str, float]] | None:
    try:
        async with httpx.AsyncClient(timeout=20.0) as client:
            response = await client.get(_SIMILAR_ARTISTS_URL, params={"artist_mbids": mbid, "algorithm": _ALGORITHM})
        response.raise_for_status()
        payload = response.json()
    except (httpx.HTTPError, ValueError) as e:
        logger.warning(f"ListenBrainz 유사 아티스트 조회 실패 (mbid={mbid}): {e}")
        return None

    if not isinstance(payload, list):
        logger.warning(f"ListenBrainz 응답 형태가 예상과 다름 (mbid={mbid})")
        return None
    return [
        (a["artist_mbid"], a["name"], float(a.get("score") or 0))
        for a in payload
        if isinstance(a, dict) and a.get("artist_mbid") and a.get("name")
    ]


# 공연 아티스트 표기와 mbid를 잇는 색인 - (표기 -> mbid, mbid -> 저장할 이름). 우선순위는
# find_canonical_by_alias와 같고(별칭 먼저, mbid 있는 쪽 우선), 표기가 수천 개라 한 번에 읽음
async def _build_artist_index(db: AsyncSession, concert_names: set[str]) -> tuple[dict[str, str], dict[str, str]]:
    canonical_rows = (
        await db.execute(select(CanonicalArtist.id, CanonicalArtist.mbid, CanonicalArtist.canonical_name))
    ).all()
    alias_rows = (await db.execute(select(ArtistAlias.canonical_artist_id, ArtistAlias.alias_text))).all()

    mbid_by_id = {row.id: row.mbid for row in canonical_rows}
    mbid_by_canonical_name: dict[str, str] = {}
    for row in canonical_rows:
        if row.mbid:
            mbid_by_canonical_name.setdefault(row.canonical_name.strip().lower(), row.mbid)
    mbid_by_alias: dict[str, str | None] = {}
    for canonical_id, alias_text in alias_rows:
        key = alias_text.strip().lower()
        mbid_by_alias[key] = mbid_by_alias.get(key) or mbid_by_id.get(canonical_id)

    mbid_by_name: dict[str, str] = {}
    for name in concert_names:
        key = name.lower()
        mbid = mbid_by_alias[key] if key in mbid_by_alias else mbid_by_canonical_name.get(key)
        if mbid:
            mbid_by_name[name] = mbid

    # 추천은 공연에 적힌 표기로 대조하므로, 공연이 있는 아티스트는 그 표기 하나로 저장(canonical
    # 이름과 같은 표기 우선). 공연이 없는 아티스트는 나중에 공연이 생길 때를 위해 canonical 이름
    stored_name_by_mbid = {row.mbid: row.canonical_name for row in canonical_rows if row.mbid}
    canonical_lower = {mbid: name.strip().lower() for mbid, name in stored_name_by_mbid.items()}
    concert_name_by_mbid: dict[str, str] = {}
    for name in sorted(mbid_by_name, key=lambda n: (n.lower() != canonical_lower.get(mbid_by_name[n]), n)):
        concert_name_by_mbid.setdefault(mbid_by_name[name], name)
    stored_name_by_mbid.update(concert_name_by_mbid)

    return mbid_by_name, stored_name_by_mbid


# 원점수(수천 단위)를 아티스트별 최댓값 기준 0~1로 바꿈 - 추천이 여러 씨앗의 점수를 합산하고
# 기존 Last.fm 캐시(0~1)와도 섞이기 때문. 저장 이름이 겹치면 높은 점수 하나만 남김
def _to_scored_names(
    seed_mbid: str, similar: list[tuple[str, str, float]], stored_name_by_mbid: dict[str, str]
) -> list[tuple[str, float]]:
    others = [entry for entry in similar if entry[0] != seed_mbid]
    top = max((score for _, _, score in others), default=0)
    if top <= 0:
        return []

    best: dict[str, tuple[str, float]] = {}
    for mbid, lb_name, score in others:
        name = stored_name_by_mbid.get(mbid, lb_name)
        key = name.lower()
        if score > 0 and (key not in best or score / top > best[key][1]):
            best[key] = (name, score / top)
    return list(best.values())


# 캐싱 안 됐거나 오래된 공연 아티스트 중 mbid가 확인된 것만 ListenBrainz에서 유사 아티스트를
# (재)조회해 저장. 결과가 없으면 기존 캐시(Last.fm 포함)는 그대로 둠
async def sync_artist_similarities() -> None:
    stale_cutoff = datetime.now(timezone.utc) - _LASTFM_CACHE_TTL
    async with AsyncSessionLocal() as db:
        concert_result = await db.execute(select(Concert.artist_name).where(Concert.artist_name != []))
        all_names = {
            name.strip()
            for arr in concert_result.scalars().all()
            for name in (arr or [])
            if name and name.strip()
        }

        fresh_result = await db.execute(
            select(ArtistSimilarity.artist_name).distinct().where(ArtistSimilarity.fetched_at >= stale_cutoff)
        )
        fresh_names = set(fresh_result.scalars().all())

        mbid_by_name, stored_name_by_mbid = await _build_artist_index(db, all_names)

    # mbid 없는 표기는 상한을 걸기 전에 빼야 함 - 안 그러면 조회도 못 하는 이름이 매일 상한을 차지함
    pending = sorted(mbid_by_name.keys() - fresh_names)
    pending = await _filter_lastfm_retry_eligible(pending, _SYNC_TYPE, limit=_MAX_LASTFM_SYNC_PER_RUN)
    if not pending:
        logger.info("ListenBrainz 신규 캐싱 대상 아티스트 없음")
        return

    logger.info(f"ListenBrainz 유사 아티스트 캐싱 대상 {len(pending)}건")
    stats = {"saved": 0, "empty": 0, "failed": 0}
    consecutive_errors = 0
    for i, artist_name in enumerate(pending):
        if i > 0:
            await asyncio.sleep(_REQUEST_INTERVAL)

        # 한 아티스트에서 예기치 못한 오류(DB 오류 등)가 나도 이후 아티스트들은 계속 처리
        try:
            seed_mbid = mbid_by_name[artist_name]
            similar = await fetch_similar_artists(seed_mbid)
            if similar is None:
                stats["failed"] += 1
                consecutive_errors += 1
                if consecutive_errors >= _MAX_CONSECUTIVE_ERRORS:
                    logger.error(f"ListenBrainz 호출이 {consecutive_errors}번 연속 실패 - 유사 아티스트 캐싱 중단")
                    break
                continue
            consecutive_errors = 0

            scored = _to_scored_names(seed_mbid, similar, stored_name_by_mbid)
            if not scored:
                await _record_lastfm_failure(artist_name, _SYNC_TYPE)
                stats["empty"] += 1
                continue

            async with AsyncSessionLocal() as db:
                await db.execute(delete(ArtistSimilarity).where(ArtistSimilarity.artist_name == artist_name))
                db.add_all(
                    [
                        ArtistSimilarity(artist_name=artist_name, similar_artist_name=name, match_score=score)
                        for name, score in scored
                    ]
                )
                await _clear_lastfm_failure(db, artist_name, _SYNC_TYPE)
                await db.commit()
            stats["saved"] += 1
        except Exception as e:
            stats["failed"] += 1
            logger.warning(f"ListenBrainz 아티스트 캐싱 실패, 다음으로 계속 ({artist_name}): {e}")

    logger.info(f"ListenBrainz 유사 아티스트 캐싱 완료: {stats}")
