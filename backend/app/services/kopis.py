import re
from datetime import datetime, date, timedelta, timezone
from xml.etree import ElementTree as ET

import httpx
from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.models.concert import Concert
from app.models.social import ArtistFollow, NewsFeed

_DATE_FMT = "%Y.%m.%d"

_FESTIVAL_KEYWORDS = [
    "festival", "fest", "페스티벌", "페스", "뮤직페스",
]


# 공연명 기반 단독 공연 / 페스티벌 분류
def _classify_event_type(name: str) -> str:
    lower = name.lower()
    if any(kw in lower for kw in _FESTIVAL_KEYWORDS):
        return "FESTIVAL"
    return "SOLO"


# 공연 기간 파싱 ("YYYY.MM.DD" -> datetime)
def _parse_date(s: str) -> datetime:
    return datetime.strptime(s.strip(), _DATE_FMT).replace(tzinfo=timezone.utc)


# 가격 파싱 ("VIP석 150,000원, R석 110,000원" -> [{"seat_type": "VIP석", "price": 150000}])
def _parse_price(text: str) -> list[dict] | None:
    prices = []
    for match in re.finditer(r"([^\s,]+)\s+([\d,]+)원", text):
        prices.append({
            "seat_type": match.group(1),
            "price": int(match.group(2).replace(",", "")),
        })
    return prices or None


# 아티스트 파싱 ("연출: A, 출연: B, C" -> ["B", "C"])
def _parse_artists(prfcrew: str) -> list[str]:
    match = re.search(r"출연\s*:\s*(.+)", prfcrew)
    raw = match.group(1) if match else prfcrew
    return [a.strip() for a in raw.split(",") if a.strip()]


# concert 정보 DB upsert
async def _upsert_concert(db: AsyncSession, data: dict) -> Concert:
    result = await db.execute(
        select(Concert).where(Concert.kopis_id == data["kopis_id"])
    )
    concert = result.scalar_one_or_none()

    # 공연이 없으면 새로 생성
    if concert is None:
        concert = Concert(**data)
        db.add(concert)
    # 공연이 있으면 덮어쓰기
    else:
        for key, value in data.items():
            existing = getattr(concert, key, None)
            # 빈 배열로 기존 데이터 덮어쓰기 방지
            if isinstance(value, list) and not value and existing:
                continue
            if value is not None:
                setattr(concert, key, value)

    return concert


# KOPIS 공연 검색 (keyword, start_date, end_date -> Concert 목록 + DB upsert)
async def search_concerts(
    db: AsyncSession,
    keyword: str,
    start_date: date | None = None,
    end_date: date | None = None,
) -> list[Concert]:
    today = date.today()
    params = {
        "service": settings.KOPIS_API_KEY,
        "stdate": (start_date or today - timedelta(days=365)).strftime("%Y%m%d"),
        "eddate": (end_date or today + timedelta(days=365)).strftime("%Y%m%d"),
        "shprfnm": keyword,
        "rows": 50,
        "cpage": 1,
    }

    async with httpx.AsyncClient(timeout=10.0) as client:
        response = await client.get(f"{settings.KOPIS_BASE_URL}/pblprfr", params=params)

    if response.status_code != 200:
        raise HTTPException(status_code=502, detail="KOPIS API 호출에 실패했습니다.")

    root = ET.fromstring(response.content)
    kopis_ids: list[str] = []

    # KOPIS 공연 정보 파싱
    for elem in root.findall("db"):
        kopis_id = (elem.findtext("mt20id") or "").strip()
        start_raw = (elem.findtext("prfpdfrom") or "").strip()
        end_raw = (elem.findtext("prfpdto") or "").strip()

        if not kopis_id or not start_raw or not end_raw:
            continue

        # 목록 API에서는 출연진·상세·가격 미제공
        name = elem.findtext("prfnm") or ""
        data = {
            "kopis_id": kopis_id,
            "name": name,
            "artist_name": [],
            "venue": elem.findtext("fcltynm") or None,
            "start_date": _parse_date(start_raw),
            "end_date": _parse_date(end_raw),
            "genre": [g for g in [elem.findtext("genrenm")] if g],
            "poster_url": elem.findtext("poster") or None,
            "event_type": _classify_event_type(name),
        }
        await _upsert_concert(db, data)
        kopis_ids.append(kopis_id)

    if not kopis_ids:
        return []

    await db.commit()

    # commit 후 재조회
    result = await db.execute(
        select(Concert).where(Concert.kopis_id.in_(kopis_ids))
    )
    return list(result.scalars().all())


# concert.artist_name 기반으로 팔로우 유저들에게 뉴스피드 생성 (중복 제외)
async def _create_news_feeds_for_concert(db: AsyncSession, concert: Concert) -> None:
    if not concert.artist_name:
        return

    result = await db.execute(select(ArtistFollow))
    follows = result.scalars().all()
    if not follows:
        return

    concert_artists_lower = {a.lower() for a in concert.artist_name}

    for follow in follows:
        matched_artist = next(
            (
                entry.get("artist_name")
                for entry in (follow.artists or [])
                if entry.get("artist_name", "").lower() in concert_artists_lower
            ),
            None,
        )
        if matched_artist is None:
            continue

        # 중복 방지
        dup = await db.execute(
            select(NewsFeed).where(
                NewsFeed.user_id == follow.user_id,
                NewsFeed.concert_id == concert.id,
            )
        )
        if dup.scalar_one_or_none() is not None:
            continue

        db.add(NewsFeed(user_id=follow.user_id, concert_id=concert.id, artist_name=matched_artist))


# KOPIS 공연 상세 조회 (kopis_id -> Concert + DB upsert)
async def get_concert_detail(db: AsyncSession, kopis_id: str) -> Concert:
    async with httpx.AsyncClient(timeout=10.0) as client:
        response = await client.get(
            f"{settings.KOPIS_BASE_URL}/pblprfr/{kopis_id}",
            params={"service": settings.KOPIS_API_KEY},
        )

    if response.status_code != 200:
        raise HTTPException(status_code=502, detail="KOPIS API 호출에 실패했습니다.")

    root = ET.fromstring(response.content)
    elem = root.find("db")
    if elem is None:
        raise HTTPException(status_code=404, detail="공연 정보를 찾을 수 없습니다.")

    # 공연 상세 정보 파싱
    start_raw = (elem.findtext("prfpdfrom") or "").strip()
    end_raw = (elem.findtext("prfpdto") or "").strip()
    prfcrew = (elem.findtext("prfcrew") or "").strip()
    pcseguidance = (elem.findtext("pcseguidance") or "").strip()

    name = elem.findtext("prfnm") or ""
    data = {
        "kopis_id": kopis_id,
        "name": name,
        "artist_name": _parse_artists(prfcrew) if prfcrew else [],
        "venue": elem.findtext("fcltynm") or None,
        "start_date": _parse_date(start_raw),
        "end_date": _parse_date(end_raw),
        "genre": [g for g in [elem.findtext("genrenm")] if g],
        "poster_url": elem.findtext("poster") or None,
        "description": elem.findtext("sty") or None,
        "price": _parse_price(pcseguidance),
        "event_type": _classify_event_type(name),
    }

    concert = await _upsert_concert(db, data)
    await _create_news_feeds_for_concert(db, concert)
    await db.commit()
    await db.refresh(concert)
    return concert
