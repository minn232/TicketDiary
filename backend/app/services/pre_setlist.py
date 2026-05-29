import json
from collections import Counter
from uuid import UUID

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.concert import Concert
from app.models.setlist import PreSetlist
from app.schemas.setlist import SongEntry
from app.services.setlistfm import search_setlists_by_artist


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

    pre_setlist.songs = json.dumps([s.model_dump() for s in songs], ensure_ascii=False)
    pre_setlist.is_user_edited = True
    pre_setlist.edited_user_nickname = nickname or "익명"

    await db.commit()
    await db.refresh(pre_setlist)
    return pre_setlist


# 아티스트 과거 공연 데이터 기반 예상 셋리스트 생성 및 저장
async def generate_pre_setlist(
    db: AsyncSession, concert_id: UUID, top_n: int = 20
) -> PreSetlist:
    concert = await _get_concert(db, concert_id)

    if not concert.artist_name:
        raise HTTPException(status_code=400, detail="공연에 아티스트 정보가 없습니다.")

    # 아티스트 이름으로 Setlist.fm에서 과거 공연 데이터 검색
    raw_setlists = await search_setlists_by_artist(concert.artist_name[0], pages=3)

    if not raw_setlists:
        raise HTTPException(status_code=404, detail="해당 아티스트의 셋리스트 데이터를 찾을 수 없습니다.")

    # 곡별 등장 횟수 및 앙코르 횟수 집계
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

    # 상위 top_n 곡 선정 (앙코르 여부는 과반수 기준)
    top_songs = []
    for key, count in song_counts.most_common(top_n):
        top_songs.append({
            "name": name_map[key],
            "encore": song_encore_counts[key] > count / 2,
        })

    songs_json = json.dumps(top_songs, ensure_ascii=False)

    # DB upsert
    result = await db.execute(select(PreSetlist).where(PreSetlist.concert_id == concert_id))
    pre_setlist = result.scalar_one_or_none()

    if pre_setlist is None:
        pre_setlist = PreSetlist(concert_id=concert_id, songs=songs_json)
        db.add(pre_setlist)
    else:
        pre_setlist.songs = songs_json
        pre_setlist.setlistfm_id = None
        pre_setlist.is_user_edited = False
        pre_setlist.edited_user_nickname = None

    await db.commit()
    await db.refresh(pre_setlist)
    return pre_setlist
