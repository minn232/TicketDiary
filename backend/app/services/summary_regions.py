# 결산 지역별 관람 - 공연장 이름으로 추측하지 않고 KOPIS 시설 좌표만 씀
import asyncio
import time
from collections import Counter, OrderedDict
from xml.etree import ElementTree as ET
from uuid import UUID

import httpx
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.models.concert import Concert
from app.models.ticket import Ticket, TicketStatus
from app.services.kopis import throttle_kopis_request
from app.services.summary import _period_start

# 프로세스 메모리 캐시(공개 시설 좌표만 담음, 상한 2048개). 조회 실패는 60초만 기억해
# KOPIS 일시 오류가 지나면 다시 시도됨
_cache: OrderedDict[str, tuple[float, tuple[float, float] | None]] = OrderedDict()
_lookup_limit = asyncio.Semaphore(3)


# KOPIS XML 조회(KOPIS 요청 간격 제한을 같이 지킴)
async def _xml(client: httpx.AsyncClient, path: str) -> ET.Element:
    await throttle_kopis_request()
    response = await client.get(
        f"{settings.KOPIS_BASE_URL}/{path}",
        params={"service": settings.KOPIS_API_KEY},
    )
    response.raise_for_status()
    return ET.fromstring(response.content)


# KOPIS 공연 id -> 공연장 좌표. 국내 범위 밖이거나 못 찾으면 None
async def _coordinates(client: httpx.AsyncClient, kopis_id: str) -> tuple[float, float] | None:
    cached = _cache.get(kopis_id)
    if cached and cached[0] > time.monotonic():
        _cache.move_to_end(kopis_id)
        return cached[1]
    if not settings.KOPIS_API_KEY:
        return None
    value = None
    async with _lookup_limit:
        try:
            # 공연 id로 시설을 찾음 - 이름이 같은 다른 도시 공연장이 이 공연장으로 섞이지 않게
            concert = await _xml(client, f"pblprfr/{kopis_id}")
            facility_id = concert.findtext(".//mt10id")
            if facility_id:
                facility = await _xml(client, f"prfplc/{facility_id.strip()}")
                lat = float(facility.findtext(".//la") or "nan")
                lon = float(facility.findtext(".//lo") or "nan")
                if 32 <= lat <= 39.5 and 124 <= lon <= 132:
                    value = (lat, lon)
        except (httpx.HTTPError, ET.ParseError, ValueError):
            pass
    _cache[kopis_id] = (time.monotonic() + (86400 if value else 60), value)
    _cache.move_to_end(kopis_id)
    while len(_cache) > 2048:
        _cache.popitem(last=False)
    return value


# 기간 내 관람 완료 티켓을 공연장 좌표별로 집계. 좌표를 못 찾은 건 unresolved_count로 따로 내림
async def get_regional_summary(db: AsyncSession, user_id: UUID, period: str) -> dict:
    # 여러 날 공연은 공연 첫날보다 실제 관람일 우선
    attended = func.coalesce(Ticket.attended_date, Concert.start_date)
    query = select(Concert.kopis_id).join(Ticket, Ticket.concert_id == Concert.id).where(
        Ticket.user_id == user_id, Ticket.status == TicketStatus.AFTER_CONCERT,
    )
    start = _period_start(period)
    if start:
        query = query.where(attended >= start)
    result = await db.execute(query)
    concert_ids = list(result.scalars().all())
    frequencies = Counter(concert_ids)
    counts: Counter = Counter()
    resolved = 0
    async with httpx.AsyncClient(timeout=5) as client:
        async def locate(kopis_id: str, count: int) -> None:
            nonlocal resolved
            coords = await _coordinates(client, kopis_id)
            if coords is not None:
                counts[coords] += count
                resolved += count
        # 기록이 많아 KOPIS 간격 제한에 밀려도 요청 전체를 7초로 제한함. 못 끝낸 건 unresolved로 남김
        try:
            async with asyncio.timeout(7):
                await asyncio.gather(*(locate(k, n) for k, n in frequencies.items() if k))
        except TimeoutError:
            pass
    return {
        "period": period, "concert_count": len(concert_ids),
        "unresolved_count": len(concert_ids) - resolved,
        "locations": [{"latitude": lat, "longitude": lon, "count": count}
                      for (lat, lon), count in sorted(counts.items())],
    }
