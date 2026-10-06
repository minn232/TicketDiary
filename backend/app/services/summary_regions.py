"""Regional attendance: exact KOPIS facility coordinates, never venue-name guesses."""
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

# Bounded, process-local cache contains public facility coordinates only.
# A failed lookup expires quickly so transient provider failures are retryable.
_cache: OrderedDict[str, tuple[float, tuple[float, float] | None]] = OrderedDict()
_lookup_limit = asyncio.Semaphore(3)


async def _xml(client: httpx.AsyncClient, path: str) -> ET.Element:
    await throttle_kopis_request()
    response = await client.get(
        f"{settings.KOPIS_BASE_URL}/{path}",
        params={"service": settings.KOPIS_API_KEY},
    )
    response.raise_for_status()
    return ET.fromstring(response.content)


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
            # Resolve the facility from the performance id: identically named
            # venues in other cities must not silently count toward this venue.
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


async def get_regional_summary(db: AsyncSession, user_id: UUID, period: str) -> dict:
    # Actual attendance date takes precedence over the first day of a tour/run.
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
        # Bound the entire request, including throttling for large histories.
        # Any unfinished locations remain explicit unresolved records.
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
