import asyncio
import logging
import re
from datetime import datetime, date, timedelta, timezone
from xml.etree import ElementTree as ET

import httpx
from fastapi import HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.models.concert import Concert
from app.models.social import ArtistFollow, NewsFeed

logger = logging.getLogger(__name__)

_DATE_FMT = "%Y.%m.%d"

_FESTIVAL_KEYWORDS = [
    "festival", "fest", "페스티벌", "페스", "뮤직페스",
]

_SITE_NAME_MAP = {
    "yes24": "YES24",
    "예스24": "YES24",
    "인터파크": "INTERPARK",
    "티켓링크": "TICKETLINK",
    "멜론티켓": "MELON",
    "멜론": "MELON",
}


# KOPIS relates relatenm → 표준 사이트 키 변환
def _normalize_site_name(name: str) -> str | None:
    normalized = name.lower().replace(" ", "")
    for key, value in _SITE_NAME_MAP.items():
        if key.lower().replace(" ", "") in normalized:
            return value
    return None


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


# KOPIS 공연 검색 단일 호출 (keyword 그대로 사용)
async def _search_concerts_once(
    db: AsyncSession,
    keyword: str,
    start_date: date | None,
    end_date: date | None,
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

    for elem in root.findall("db"):
        kopis_id = (elem.findtext("mt20id") or "").strip()
        start_raw = (elem.findtext("prfpdfrom") or "").strip()
        end_raw = (elem.findtext("prfpdto") or "").strip()

        if not kopis_id or not start_raw or not end_raw:
            continue

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

    result = await db.execute(
        select(Concert).where(Concert.kopis_id.in_(kopis_ids))
    )
    return list(result.scalars().all())


# KOPIS 공연 검색 (keyword, start_date, end_date -> Concert 목록 + DB upsert)
# 결과 없으면 keyword 끝 단어를 하나씩 줄여 재시도 (최소 2단어)
async def search_concerts(
    db: AsyncSession,
    keyword: str,
    start_date: date | None = None,
    end_date: date | None = None,
) -> list[Concert]:
    words = keyword.split()
    min_words = min(2, len(words))
    for end in range(len(words), min_words - 1, -1):
        q = " ".join(words[:end])
        concerts = await _search_concerts_once(db, q, start_date, end_date)
        if concerts:
            if q != keyword:
                logger.info(f"KOPIS 검색어 축소: {keyword!r} → {q!r} ({len(concerts)}건)")
            return concerts
    return []


# concert.artist_name 기반으로 팔로우 유저들에게 뉴스피드 생성 (중복 제외)
async def _create_news_feeds_for_concert(db: AsyncSession, concert: Concert) -> None:
    if not concert.artist_name:
        return

    concert_artists_lower = {a.lower() for a in concert.artist_name}

    # 아티스트를 1명 이상 팔로우하는 유저만 조회 (빈 배열 제외)
    result = await db.execute(
        select(ArtistFollow).where(
            func.jsonb_array_length(ArtistFollow.artists) > 0
        )
    )
    follows = result.scalars().all()
    if not follows:
        return

    # 매칭되는 팔로워 및 아티스트명 수집
    matched: list[tuple] = []
    for follow in follows:
        artist = next(
            (
                entry.get("artist_name")
                for entry in (follow.artists or [])
                if entry.get("artist_name", "").lower() in concert_artists_lower
            ),
            None,
        )
        if artist:
            matched.append((follow.user_id, artist))

    if not matched:
        return

    # 이미 존재하는 뉴스피드 일괄 조회 (N+1 방지)
    matched_user_ids = [uid for uid, _ in matched]
    existing_result = await db.execute(
        select(NewsFeed.user_id).where(
            NewsFeed.concert_id == concert.id,
            NewsFeed.user_id.in_(matched_user_ids),
        )
    )
    existing_user_ids = set(existing_result.scalars().all())

    for user_id, artist_name in matched:
        if user_id not in existing_user_ids:
            db.add(NewsFeed(user_id=user_id, concert_id=concert.id, artist_name=artist_name))


# KOPIS 일별 배치: 신규 공연 수집 + 뉴스피드 생성
async def sync_daily_concerts(db: AsyncSession) -> None:
    today = date.today()
    end_date = today + timedelta(days=365)

    params = {
        "service": settings.KOPIS_API_KEY,
        "stdate": today.strftime("%Y%m%d"),
        "eddate": end_date.strftime("%Y%m%d"),
        "genrenm": "대중음악",
        "rows": 100,
        "cpage": 1,
    }

    async with httpx.AsyncClient(timeout=10.0) as client:
        response = await client.get(f"{settings.KOPIS_BASE_URL}/pblprfr", params=params)

    if response.status_code != 200:
        logger.warning("KOPIS 배치 목록 조회 실패")
        return

    root = ET.fromstring(response.content)
    kopis_ids = [
        elem.findtext("mt20id", "").strip()
        for elem in root.findall("db")
        if elem.findtext("mt20id", "").strip()
    ]

    if not kopis_ids:
        return

    # DB에 이미 있는 공연 조회
    result = await db.execute(
        select(Concert).where(Concert.kopis_id.in_(kopis_ids))
    )
    existing = {c.kopis_id: c for c in result.scalars().all()}

    for kopis_id in kopis_ids:
        concert = existing.get(kopis_id)

        if concert is None:
            # 신규 공연: 상세 조회 + 뉴스피드 생성 (get_concert_detail 내부에서 처리)
            try:
                await get_concert_detail(db, kopis_id)
                await asyncio.sleep(0.2)
            except Exception as e:
                logger.warning(f"KOPIS 상세 조회 실패 ({kopis_id}): {e}")
        elif concert.artist_name:
            # 이미 있고 아티스트 정보 있음: API 재호출 없이 뉴스피드만 생성
            await _create_news_feeds_for_concert(db, concert)
            await db.commit()


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

    # relates 파싱: 예매 사이트 링크 추출
    ticketing_links: dict[str, str] = {}
    relates_elem = elem.find("relates")
    if relates_elem is not None:
        for relate in relates_elem.findall("relate"):
            site_name = (relate.findtext("relatenm") or "").strip()
            site_url = (relate.findtext("relateurl") or "").strip()
            if site_name and site_url:
                key = _normalize_site_name(site_name)
                if key:
                    ticketing_links[key] = site_url

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
        "ticketing_links": ticketing_links or None,
    }

    concert = await _upsert_concert(db, data)
    await _create_news_feeds_for_concert(db, concert)
    await db.commit()
    await db.refresh(concert)
    return concert
