"""헤드라이너 판정(C 트랙) 후보 공연을 서버 DB에서 읽기 전용으로 내보내는 스크립트.

단독공연(SOLO)인데 아티스트가 2명 이상인 공연 = 게스트/오프닝이 섞였을 가능성이 있는 공연.
공연명/설명/포스터 URL/아티스트별 canonical(mbid)을 함께 뽑아, 로컬에서 샘플링해 사용자가 직접
헤드라이너를 라벨링하고 판정 규칙(공연명 포함/예매처 문구/인지도)의 정확도를 잼.

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/backtest/export_headliner_samples.py
"""

import asyncio
import json
import sys
from pathlib import Path

_BACKEND_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_BACKEND_ROOT))

from sqlalchemy import func, select  # noqa: E402

from app.core.database import AsyncSessionLocal, engine  # noqa: E402
from app.models.artist_normalization import ArtistAlias, CanonicalArtist  # noqa: E402
from app.models.concert import Concert, EventType  # noqa: E402
from app.models.lineup import ConcertLineup  # noqa: E402

engine.echo = False

_OUT_DIR = Path(__file__).resolve().parent / "input"
_DESCRIPTION_LIMIT = 600


async def main() -> None:
    async with AsyncSessionLocal() as db:
        concerts = (
            await db.execute(
                select(Concert)
                .where(
                    Concert.event_type == EventType.SOLO.value,
                    func.cardinality(Concert.artist_name) >= 2,
                )
                .order_by(Concert.start_date.desc())
            )
        ).scalars().all()

        # 표기(소문자) -> canonical(id, mbid, 이름) + canonical별 전체 표기(별칭/이름/표시명) - 공연명에 다른 표기로
        # 적혀 있어도 같은 아티스트로 인식하려고 함. find_canonical_by_alias와 같은 기준
        canonicals = (await db.execute(select(CanonicalArtist))).scalars().all()
        alias_rows = await db.execute(select(ArtistAlias.canonical_artist_id, ArtistAlias.alias_text))
        names_by_id: dict = {c.id: {c.canonical_name, c.display_name} - {None} for c in canonicals}
        for canonical_id, alias_text in alias_rows.all():
            names_by_id.setdefault(canonical_id, set()).add(alias_text)
        by_text: dict = {}
        for c in canonicals:
            for text in names_by_id[c.id]:
                by_text.setdefault(text.strip().lower(), c)

        lineup_rows = await db.execute(
            select(ConcertLineup.concert_id, ConcertLineup.artist, ConcertLineup.performance_date, ConcertLineup.source)
            .where(ConcertLineup.concert_id.in_([c.id for c in concerts]))
        )
        lineups: dict = {}
        for concert_id, artist, performance_date, source in lineup_rows.all():
            lineups.setdefault(str(concert_id), []).append(
                {"artist": artist, "date": performance_date.isoformat(), "source": source}
            )

    result = []
    for c in concerts:
        artists = []
        for name in c.artist_name:
            canonical = by_text.get(name.strip().lower())
            artists.append({
                "text": name,
                "mbid": canonical.mbid if canonical else None,
                "canonical_name": canonical.canonical_name if canonical else None,
                "aliases": sorted(names_by_id[canonical.id]) if canonical else [],
            })
        result.append({
            "concert_id": str(c.id),
            "name": c.name,
            "start_date": c.start_date.date().isoformat(),
            "venue": c.venue,
            "description": (c.description or "")[:_DESCRIPTION_LIMIT],
            "poster_url": c.poster_url,
            "crawl_screenshot_url": c.crawl_screenshot_url,
            "artists": artists,
            "lineup": lineups.get(str(c.id), []),
        })

    _OUT_DIR.mkdir(exist_ok=True)
    (_OUT_DIR / "headliner_candidates.json").write_text(json.dumps(result, ensure_ascii=False, indent=1), "utf-8")
    print(f"SOLO 다인 공연 {len(result)}건 -> {_OUT_DIR / 'headliner_candidates.json'}")
    await engine.dispose()


if __name__ == "__main__":
    asyncio.run(main())
