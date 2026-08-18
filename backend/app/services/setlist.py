import asyncio
import logging
from datetime import date, datetime, timedelta, timezone
from uuid import UUID

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import AsyncSessionLocal
from app.models.concert import Concert
from app.models.setlist import RealSetlist
from app.models.ticket import Ticket
from app.schemas.setlist import SongEntry
from app.services.setlistfm import search_setlists, get_setlist_by_id, extract_songs

logger = logging.getLogger(__name__)


# concert 조회 (없으면 404)
async def _get_concert(db: AsyncSession, concert_id: UUID) -> Concert:
    result = await db.execute(select(Concert).where(Concert.id == concert_id))
    concert = result.scalar_one_or_none()
    if concert is None:
        raise HTTPException(status_code=404, detail="공연 정보를 찾을 수 없습니다.")
    return concert


# 실제 셋리스트가 적용될 날짜를 결정. explicit_date가 오면 그대로 쓰고(티켓의 attended_date
# 등), 없으면 하루짜리 공연일 때만 concert.start_date로 자동 결정. 여러 날짜에 걸친 공연인데
# 날짜를 특정할 방법이 없으면(예: attended_date 없는 티켓) 400으로 명확히 안내 -
# concert_id 하나에 날짜 다른 셋리스트가 여러 개 있을 수 있어서 추측하면 안 됨
def resolve_performance_date(concert: Concert, explicit_date: date | None) -> date:
    if explicit_date is not None:
        return explicit_date
    if concert.start_date.date() == concert.end_date.date():
        return concert.start_date.date()
    raise HTTPException(status_code=400, detail="여러 날짜에 걸친 공연입니다. 날짜를 지정해주세요.")


# DB에서 real setlist 조회. row가 없어도(Setlist.fm에서 아직 못 찾음 등) 404 대신
# concert.artist_name을 채운 빈 응답을 돌려줌 - 프론트가 "아티스트는 등록돼 있는데
# 셋리스트만 아직 없음"을 구분해서 아티스트별 placeholder를 보여줄 수 있게 하기 위함
# (기존엔 404라 프론트가 아티스트 목록 자체를 몰라 통째로 안내 문구만 표시했음).
# 반환 타입이 RealSetlist | dict로 갈리는데, 둘 다 response_model(RealSetlistResponse,
# from_attributes=True)이 그대로 직렬화하므로 호출부(엔드포인트)는 신경 쓸 필요 없음.
async def get_real_setlist(
    db: AsyncSession, concert_id: UUID, explicit_date: date | None = None
) -> RealSetlist | dict:
    concert = await _get_concert(db, concert_id)
    performance_date = resolve_performance_date(concert, explicit_date)

    result = await db.execute(
        select(RealSetlist).where(
            RealSetlist.concert_id == concert_id,
            RealSetlist.performance_date == performance_date,
        )
    )
    real_setlist = result.scalar_one_or_none()
    if real_setlist is None:
        return {
            "id": None,
            "concert_id": concert_id,
            "performance_date": performance_date,
            "setlistfm_id": None,
            "songs": [],
            "is_user_edited": False,
            "edited_user_nickname": None,
            "artist_names": concert.artist_name or [],
        }

    # RealSetlist 테이블엔 없는 필드라, 응답 직렬화 때만 쓰도록 인스턴스에 임시로 붙임.
    real_setlist.artist_names = concert.artist_name or []
    return real_setlist


# concert의 아티스트, 공연일 기반 Setlist.fm 검색 -> 후보 목록 반환
async def search_setlists_for_concert(
    db: AsyncSession, concert_id: UUID, explicit_date: date | None = None
) -> list[dict]:
    concert = await _get_concert(db, concert_id)

    if not concert.artist_name:
        raise HTTPException(status_code=400, detail="공연에 아티스트 정보가 없습니다.")

    performance_date = resolve_performance_date(concert, explicit_date)
    return await search_setlists(concert.artist_name[0], performance_date)


# 유저가 직접 곡 목록 수정
async def update_real_setlist(
    db: AsyncSession,
    concert_id: UUID,
    songs: list[SongEntry],
    nickname: str | None,
    explicit_date: date | None = None,
) -> RealSetlist:
    concert = await _get_concert(db, concert_id)
    performance_date = resolve_performance_date(concert, explicit_date)

    result = await db.execute(
        select(RealSetlist).where(
            RealSetlist.concert_id == concert_id,
            RealSetlist.performance_date == performance_date,
        )
    )
    real_setlist = result.scalar_one_or_none()
    if real_setlist is None:
        raise HTTPException(status_code=404, detail="셋리스트를 찾을 수 없습니다.")

    real_setlist.songs = [s.model_dump() for s in songs]
    real_setlist.is_user_edited = True
    real_setlist.edited_user_nickname = nickname or "익명"

    await db.commit()
    await db.refresh(real_setlist)
    return real_setlist


# setlistfm_id로 셋리스트 가져와 DB upsert
async def fetch_and_save_real_setlist(
    db: AsyncSession,
    concert_id: UUID,
    setlistfm_id: str,
    explicit_date: date | None = None,
) -> RealSetlist:
    concert = await _get_concert(db, concert_id)
    performance_date = resolve_performance_date(concert, explicit_date)

    # Setlist.fm에서 가져와 곡 목록 파싱
    setlist_data = await get_setlist_by_id(setlistfm_id)
    songs = extract_songs(setlist_data)

    # DB upsert (concert_id + performance_date 조합 기준)
    result = await db.execute(
        select(RealSetlist).where(
            RealSetlist.concert_id == concert_id,
            RealSetlist.performance_date == performance_date,
        )
    )
    real_setlist = result.scalar_one_or_none()

    if real_setlist is None:
        real_setlist = RealSetlist(
            concert_id=concert_id,
            performance_date=performance_date,
            setlistfm_id=setlistfm_id,
            songs=songs,
        )
        db.add(real_setlist)
    else:
        # 기존 셋리스트 덮어씀 (유저 편집 이력 초기화)
        real_setlist.setlistfm_id = setlistfm_id
        real_setlist.songs = songs
        real_setlist.is_user_edited = False
        real_setlist.edited_user_nickname = None

    await db.commit()
    await db.refresh(real_setlist)
    return real_setlist


# 아티스트별로 자동 검색+병합해서 실제 셋리스트 저장(유저 선택 없음) - concert.artist_name을
# 순회해서 페스티벌/단독 공연 다 동작. retry_real_setlist_generation()의 매일 백필 잡용,
# 기존 수동 검색/선택 흐름과는 완전히 별도 경로.
# search_setlists(artist, date)로 가장 근접한 후보를 자동으로 고르는 방식이라 동명이인/
# 같은 날 다른 도시 공연이 섞이면 틀릴 수 있음(정확도 낮음) - 그래서 수동 흐름도 남겨둠.
async def generate_real_setlist_auto(
    db: AsyncSession,
    concert_id: UUID,
    explicit_date: date | None = None,
) -> RealSetlist:
    concert = await _get_concert(db, concert_id)
    if not concert.artist_name:
        raise HTTPException(status_code=400, detail="공연에 아티스트 정보가 없습니다.")
    performance_date = resolve_performance_date(concert, explicit_date)

    all_songs: list[dict] = []
    matched_ids: list[str] = []
    for i, artist in enumerate(concert.artist_name):
        if i > 0:
            # search_setlists_by_artist(pre_setlist.py 경로)의 페이지 간 sleep과 동일한 이유 -
            # 아티스트 많은 페스티벌에서 Setlist.fm에 순간적으로 요청이 몰리지 않도록 간격을 둠
            await asyncio.sleep(0.5)
        candidates = await search_setlists(artist, performance_date)
        if not candidates:
            continue  # 이 아티스트만 스킵, 나머지는 계속 진행

        best = candidates[0]
        matched_ids.append(best["setlistfm_id"])
        for song in best["songs"]:
            all_songs.append({**song, "artist": artist})

    if not all_songs:
        raise HTTPException(status_code=404, detail="아티스트들의 셋리스트 데이터를 찾을 수 없습니다.")

    # DB upsert (concert_id + performance_date 조합 기준). setlistfm_id는 단독 필드라
    # 아티스트 여럿의 출처를 한 번에 표현 못 하므로, 1명만 매칭됐을 때만 채우고
    # 그 외(2명 이상 매칭)는 null로 둠(어차피 songs의 artist 태그로 출처를 알 수 있음).
    result = await db.execute(
        select(RealSetlist).where(
            RealSetlist.concert_id == concert_id,
            RealSetlist.performance_date == performance_date,
        )
    )
    real_setlist = result.scalar_one_or_none()
    setlistfm_id = matched_ids[0] if len(matched_ids) == 1 else None

    if real_setlist is None:
        real_setlist = RealSetlist(
            concert_id=concert_id,
            performance_date=performance_date,
            setlistfm_id=setlistfm_id,
            songs=all_songs,
        )
        db.add(real_setlist)
    else:
        real_setlist.setlistfm_id = setlistfm_id
        real_setlist.songs = all_songs
        real_setlist.is_user_edited = False
        real_setlist.edited_user_nickname = None

    await db.commit()
    await db.refresh(real_setlist)
    return real_setlist


# 콘서트 종료 후 이 기간 동안, Setlist.fm에 아직 안 올라온 실제 셋리스트를 매일 자동
# 재시도해 채워봄. 기간이 지나면 포기하고 유저 수동 편집을 기다림 - 시도 횟수/시작 시각을
# 따로 안 저장하고 매번 "오늘-그날짜"로 창 안인지만 판단. 이미 채워진 날짜는 쿼리에서
# 자연히 빠져서 별도 "포기" 플래그도 불필요.
_REAL_SETLIST_BACKFILL_WINDOW = timedelta(days=14)
_REAL_SETLIST_BACKFILL_CONCURRENCY = 4


# 백필 대상 (concert_id, performance_date) 하나를 처리. 실패해도 나머지에 영향 없도록 여기서
# 예외를 삼킴(generate_pre_setlist_background와 동일한 패턴) - 아티스트 데이터가 아직
# Setlist.fm에 안 올라온 건 흔한 정상 케이스라 404는 info로만 남김.
async def _backfill_real_setlist_limited(
    semaphore: asyncio.Semaphore, concert_id: UUID, performance_date: date
) -> None:
    async with semaphore:
        async with AsyncSessionLocal() as db:
            try:
                await generate_real_setlist_auto(db, concert_id, performance_date)
            except HTTPException as e:
                logger.info(
                    f"실제 셋리스트 자동 채움 스킵 (concert_id={concert_id}, date={performance_date}): {e.detail}"
                )
            except Exception as e:
                logger.warning(
                    f"실제 셋리스트 자동 채움 실패 (concert_id={concert_id}, date={performance_date}): {e}"
                )


# 매일 스케줄러가 호출. 유저가 티켓을 등록한 콘서트만 대상으로 함(아무도 안 본 공연까지
# Setlist.fm을 매일 두드릴 필요 없음) - 콘서트가 여러 날짜에 걸치면(페스티벌) 날짜마다 독립적으로
# 판단(day 1이 끝난 지 14일 지났어도 day 3가 아직 창 안이면 day 3만 계속 시도).
async def retry_real_setlist_generation() -> None:
    now = datetime.now(timezone.utc)
    today = now.date()
    earliest = today - _REAL_SETLIST_BACKFILL_WINDOW
    # DateTime(timezone=True) 컬럼과 비교하려면 date가 아니라 datetime이어야 함
    earliest_dt = datetime.combine(earliest, datetime.min.time(), tzinfo=timezone.utc)

    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(Concert)
            .join(Ticket, Ticket.concert_id == Concert.id)
            .where(Concert.end_date >= earliest_dt, Concert.start_date <= now)
            .distinct()
        )
        concerts = result.scalars().all()

        if not concerts:
            return

        existing_result = await db.execute(
            select(RealSetlist.concert_id, RealSetlist.performance_date).where(
                RealSetlist.concert_id.in_([c.id for c in concerts])
            )
        )
        existing = {(row[0], row[1]) for row in existing_result.all()}

    targets: list[tuple[UUID, date]] = []
    for concert in concerts:
        d = concert.start_date.date()
        end = concert.end_date.date()
        while d <= end:
            if earliest <= d <= today and (concert.id, d) not in existing:
                targets.append((concert.id, d))
            d += timedelta(days=1)

    if not targets:
        return

    logger.info(f"실제 셋리스트 자동 채움 대상 {len(targets)}건")
    semaphore = asyncio.Semaphore(_REAL_SETLIST_BACKFILL_CONCURRENCY)
    await asyncio.gather(
        *(_backfill_real_setlist_limited(semaphore, cid, d) for cid, d in targets)
    )
