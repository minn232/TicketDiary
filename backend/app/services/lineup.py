import logging
from datetime import date
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.lineup import ConcertLineup
from app.services.artist_matching import normalize_artist_names

logger = logging.getLogger(__name__)

# 크롤링(예매처 상세페이지)이 포스터 추출보다 신뢰도가 높다고 보고, 같은 (artist, date) row가
# 이미 있어도 더 우선순위 높은 source가 들어오면 승격시킴. 병합 정책 설계 배경은
# [[lineup_performance_date_storage_gap]] 메모리 참고
_SOURCE_PRIORITY = {"poster": 0, "crawl": 1}


# lineup 웹훅 페이로드를 concert_lineups에 union-only(삭제 없음)로 병합한다.
# - 새 (아티스트,날짜) 조합이면 추가만 함.
# - 이미 있는 조합인데 기존보다 신뢰도 높은 source가 오면 source만 승격.
# - 이 함수가 잘못 배정된 옛 row를 지우는 일은 없음(포스터가 잘못 짚은 날짜가 나중에 크롤링에
#   안 보여도 그대로 남음) - Concert.artist_name의 기존 합집합 병합 방식과 일관되게 유지.
# entries: [{"artist": str, "performance_date": "YYYY-MM-DD"}, ...] (llm_server/normalize.py의
# normalize_lineup_entries가 날짜 없는 항목은 이미 걸러서 보냄)
# known_names에 concert.artist_name을 같이 섞어 넘기면 이 콘서트의 기존 표기와 더 잘 맞음.
async def upsert_concert_lineup(
    db: AsyncSession,
    concert_id: UUID,
    entries: list[dict],
    source: str,
    known_names: set[str] | None = None,
    *,
    commit: bool = True,
) -> bool:
    if not entries:
        return False
    if source not in _SOURCE_PRIORITY:
        raise ValueError(f"알 수 없는 lineup source: {source}")

    names = [e.get("artist") for e in entries]
    normalized_names = normalize_artist_names([n for n in names if n], known_names)
    # normalize_artist_names는 빈 이름을 건너뛰므로 인덱스가 밀릴 수 있어, 원래 이름과
    # 정규화 결과를 다시 짝지어야 함 - 빈 이름이 섞인 entries만 따로 걸러 순서를 맞춘다
    valid_entries = [e for e in entries if e.get("artist")]

    parsed: list[tuple[str, date]] = []
    for entry, name in zip(valid_entries, normalized_names):
        perf_date_raw = entry.get("performance_date")
        try:
            d = date.fromisoformat(perf_date_raw)
        except (TypeError, ValueError):
            logger.warning(f"잘못된 lineup performance_date 형식, 건너뜀: {entry}")
            continue
        parsed.append((name, d))

    if not parsed:
        return False

    result = await db.execute(select(ConcertLineup).where(ConcertLineup.concert_id == concert_id))
    existing = {(row.artist, row.performance_date): row for row in result.scalars().all()}

    changed = False
    seen: set[tuple[str, date]] = set()
    for name, d in parsed:
        key = (name, d)
        if key in seen:
            continue
        seen.add(key)

        row = existing.get(key)
        if row is None:
            db.add(ConcertLineup(concert_id=concert_id, artist=name, performance_date=d, source=source))
            changed = True
        elif _SOURCE_PRIORITY[source] > _SOURCE_PRIORITY[row.source]:
            row.source = source
            changed = True

    if changed and commit:
        await db.commit()
    return changed


# 특정 날짜에 배정된 아티스트 목록. 이 콘서트에 배정 정보가 아예 없거나(도입 전 옛날 공연,
# 아직 크롤링/포스터 추출 전) 그 날짜에 아무도 배정 안 됐으면 None을 반환해서, 호출부가
# "폴백"(전체 아티스트로 표시)을 선택할 수 있게 함 - 빈 리스트와 "모른다"를 구분하기 위해
# None을 씀([] 대신).
async def get_lineup_artists_for_date(
    db: AsyncSession, concert_id: UUID, performance_date: date
) -> list[str] | None:
    result = await db.execute(
        select(ConcertLineup.artist).where(
            ConcertLineup.concert_id == concert_id,
            ConcertLineup.performance_date == performance_date,
        )
    )
    artists = [row[0] for row in result.all()]
    return artists or None
