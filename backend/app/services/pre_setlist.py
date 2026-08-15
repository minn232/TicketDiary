import logging
from collections import Counter
from uuid import UUID

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import AsyncSessionLocal
from app.models.concert import Concert
from app.models.setlist import PreSetlist
from app.schemas.setlist import SongEntry
from app.services.setlistfm import search_setlists_by_artist

logger = logging.getLogger(__name__)


# concert 조회 (없으면 404)
async def _get_concert(db: AsyncSession, concert_id: UUID) -> Concert:
    result = await db.execute(select(Concert).where(Concert.id == concert_id))
    concert = result.scalar_one_or_none()
    if concert is None:
        raise HTTPException(status_code=404, detail="공연 정보를 찾을 수 없습니다.")
    return concert


# DB에서 예상 셋리스트 조회
async def get_pre_setlist(db: AsyncSession, concert_id: UUID) -> PreSetlist:
    result = await db.execute(select(PreSetlist).where(PreSetlist.concert_id == concert_id))
    pre_setlist = result.scalar_one_or_none()
    if pre_setlist is None:
        raise HTTPException(status_code=404, detail="예상 셋리스트를 찾을 수 없습니다.")
    return pre_setlist


# 유저가 직접 곡 목록 수정
async def update_pre_setlist(
    db: AsyncSession, concert_id: UUID, songs: list[SongEntry], nickname: str | None
) -> PreSetlist:
    result = await db.execute(select(PreSetlist).where(PreSetlist.concert_id == concert_id))
    pre_setlist = result.scalar_one_or_none()
    if pre_setlist is None:
        raise HTTPException(status_code=404, detail="예상 셋리스트를 찾을 수 없습니다.")

    pre_setlist.songs = [s.model_dump() for s in songs]
    pre_setlist.is_user_edited = True
    pre_setlist.edited_user_nickname = nickname or "익명"

    await db.commit()
    await db.refresh(pre_setlist)
    return pre_setlist


# 한 아티스트의 과거 공연 데이터를 집계해 상위 n곡을 뽑음(앙코르 여부는 과반수 기준).
# Setlist.fm에 데이터가 없으면(404) 빈 리스트 - 호출부가 "이 아티스트만 스킵"할 수 있게
# 예외를 던지지 않음(페스티벌에서 아티스트 하나 데이터 없다고 전체를 실패시키면 안 됨).
async def _top_songs_for_artist(artist_name: str, n: int) -> list[dict]:
    raw_setlists = await search_setlists_by_artist(artist_name, pages=3)
    if not raw_setlists:
        return []

    song_counts: Counter = Counter()
    song_encore_counts: Counter = Counter()
    name_map: dict[str, str] = {}

    for raw in raw_setlists:
        for s in raw.get("sets", {}).get("set", []):
            is_encore = s.get("encore") is not None
            for song in s.get("song", []):
                name = (song.get("name") or "").strip()
                if name:
                    key = name.lower()
                    song_counts[key] += 1
                    if is_encore:
                        song_encore_counts[key] += 1
                    if key not in name_map:
                        name_map[key] = name

    return [
        {"name": name_map[key], "encore": song_encore_counts[key] > count / 2}
        for key, count in song_counts.most_common(n)
    ]


# 아티스트 과거 공연 데이터 기반 예상 셋리스트 생성/저장 - 페스티벌(2명 이상)이면 아티스트
# 전체를 순회해 각자 top_n(기본 20곡)씩 뽑아 artist 태그를 붙여 합침. 곡 수를 안 줄이는
# 이유는 비용이 Setlist.fm 검색/집계에서 다 발생하고 top_n은 자르는 것뿐이라(넉넉히
# 저장해도 API 호출 안 늘어남), 나중에 날짜별 매핑이 갖춰지면 재수집 없이 확장 가능.
# 단독 공연은 기존과 동일(artist 태그 없음), 이 함수만 고치면 페스티벌도 자동 커버됨.
async def generate_pre_setlist(
    db: AsyncSession, concert_id: UUID, top_n: int = 20
) -> PreSetlist:
    concert = await _get_concert(db, concert_id)

    if not concert.artist_name:
        raise HTTPException(status_code=400, detail="공연에 아티스트 정보가 없습니다.")

    artists = concert.artist_name
    is_festival = len(artists) > 1

    all_songs: list[dict] = []
    for artist in artists:
        songs = await _top_songs_for_artist(artist, top_n)
        if is_festival:
            for song in songs:
                song["artist"] = artist
        all_songs.extend(songs)

    if not all_songs:
        raise HTTPException(status_code=404, detail="해당 아티스트의 셋리스트 데이터를 찾을 수 없습니다.")

    # DB upsert
    result = await db.execute(select(PreSetlist).where(PreSetlist.concert_id == concert_id))
    pre_setlist = result.scalar_one_or_none()

    if pre_setlist is None:
        pre_setlist = PreSetlist(concert_id=concert_id, songs=all_songs)
        db.add(pre_setlist)
    else:
        pre_setlist.songs = all_songs
        pre_setlist.setlistfm_id = None
        pre_setlist.is_user_edited = False
        pre_setlist.edited_user_nickname = None

    await db.commit()
    await db.refresh(pre_setlist)
    return pre_setlist


# 티켓 등록 시 BackgroundTasks로 호출(tickets.py). 요청 세션과 분리된 자체 세션을 씀.
# Setlist.fm에 그 아티스트 데이터가 없는 경우가 흔해서(특히 인지도 낮은 아티스트) 404가
# 자주 나는데, 이건 실패가 아니라 정상적인 "데이터 없음" 케이스라 조용히 로그만 남기고
# 넘어감 - 티켓 등록 자체를 막으면 안 됨.
async def generate_pre_setlist_background(concert_id: UUID) -> None:
    async with AsyncSessionLocal() as db:
        try:
            await generate_pre_setlist(db, concert_id)
        except HTTPException as e:
            logger.info(f"예상 셋리스트 자동 생성 스킵 (concert_id={concert_id}): {e.detail}")
        except Exception as e:
            logger.warning(f"예상 셋리스트 자동 생성 실패 (concert_id={concert_id}): {e}")
