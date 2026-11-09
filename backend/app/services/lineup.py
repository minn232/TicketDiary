import logging
from datetime import date
from uuid import UUID

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.lineup import ConcertLineup
from app.services.artist_matching import normalize_artist_names

logger = logging.getLogger(__name__)

# 크롤링(예매처 상세페이지)이 포스터 추출보다 신뢰도가 높다고 보고, 같은 (artist, date) row가
# 이미 있어도 더 우선순위 높은 source가 들어오면 승격시킴. admin은 관리자 페이지에서 직접 고친 것
_SOURCE_PRIORITY = {"poster": 0, "crawl": 1, "admin": 2}


# lineup 웹훅 페이로드를 concert_lineups에 union-only(삭제 없음)로 병합 - 새 조합은 추가만
# 하고, 이미 있는 조합은 더 신뢰도 높은 source가 오면 source만 승격(row 삭제는 안 함, 기존
# artist_name 합집합 병합과 동일한 방식). entries는 날짜 없는 항목이 이미 걸러진 상태로 옴
# allowed_names가 있으면 정규화 후 그 안에 있는 이름만 반영(검수된 공연에 새 표기가 안 섞이게)
async def upsert_concert_lineup(
    db: AsyncSession,
    concert_id: UUID,
    entries: list[dict],
    source: str,
    known_names: set[str] | None = None,
    *,
    allowed_names: set[str] | None = None,
    commit: bool = True,
) -> bool:
    if not entries:
        return False
    if source not in ("poster", "crawl"):
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
        if allowed_names is not None and name not in allowed_names:
            continue
        parsed.append((name, d))

    if not parsed:
        return False

    result = await db.execute(select(ConcertLineup).where(ConcertLineup.concert_id == concert_id))
    rows = result.scalars().all()
    # 관리자가 날짜별 출연진을 고친 공연은 자동 결과로 다시 늘리지 않음 - 관리자가 뺀 조합을 LLM이 되살림
    if any(row.source == "admin" for row in rows):
        logger.info(f"관리자가 고친 lineup이라 자동 결과 무시 concert_id={concert_id}")
        return False
    existing = {(row.artist, row.performance_date): row for row in rows}

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


# 특정 날짜에 배정된 아티스트 목록. 배정 정보가 아예 없으면(옛날 공연, 크롤링/포스터 추출 전
# 등) None을 반환해서 호출부가 전체 아티스트로 폴백할 수 있게 함 - 빈 리스트와 구분하기 위함
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


# 관리자 페이지 날짜별 출연진 저장 - 이 공연의 배정을 통째로 바꾸고 전부 source="admin"으로 둠(이후
# 자동 결과는 upsert_concert_lineup이 무시). 빈 목록이면 배정을 다 지워 "모름"(전체 아티스트 폴백)으로
# 되돌리고 자동 채움도 다시 받음. 검증(날짜 범위·아티스트 표기)은 호출부가 함
async def replace_concert_lineup_by_admin(
    db: AsyncSession, concert_id: UUID, assignments: list[tuple[str, date]]
) -> None:
    await db.execute(delete(ConcertLineup).where(ConcertLineup.concert_id == concert_id))
    for name, d in sorted(set(assignments), key=lambda a: (a[1], a[0])):
        db.add(ConcertLineup(concert_id=concert_id, artist=name, performance_date=d, source="admin"))
    await db.commit()
