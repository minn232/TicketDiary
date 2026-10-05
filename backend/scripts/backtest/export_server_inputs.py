"""백테스트 입력을 서버 DB에서 읽기 전용으로 내보내는 스크립트.

로컬 DB는 거의 비어 있어서 아티스트 후보와 유저 확정 셋리(RealSetlist)는 서버에서 뽑아야 함.
DB에는 쓰지 않음. 결과 두 파일을 로컬 scripts/backtest/input/ 으로 scp해서 collect_cache.py에 씀:

  artist_candidates.json - mbid가 있는 canonical 아티스트 (이름/별칭/iTunes ID/등장 공연 수)
  real_setlists.json     - 곡이 있는 RealSetlist (공연 아티스트/형태/날짜/곡)

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/backtest/export_server_inputs.py
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
from app.models.concert import Concert  # noqa: E402
from app.models.setlist import RealSetlist  # noqa: E402

engine.echo = False

_OUT_DIR = Path(__file__).resolve().parent / "input"


# canonical 이름/별칭이 등장하는 공연 수를 세려면 Concert.artist_name(배열)을 펼쳐야 해서
# 표기 -> 공연 수 표를 먼저 만들고, canonical의 이름+별칭 표기 합으로 계산
async def _export_artists() -> list[dict]:
    async with AsyncSessionLocal() as db:
        concert_rows = await db.execute(select(Concert.artist_name))
        text_counts: dict[str, int] = {}
        for (names,) in concert_rows.all():
            for name in set(names or []):
                text_counts[name.strip()] = text_counts.get(name.strip(), 0) + 1

        canonicals = (await db.execute(select(CanonicalArtist).where(CanonicalArtist.mbid.is_not(None)))).scalars().all()
        alias_rows = await db.execute(select(ArtistAlias.canonical_artist_id, ArtistAlias.alias_text))
        aliases: dict = {}
        for canonical_id, alias_text in alias_rows.all():
            aliases.setdefault(canonical_id, set()).add(alias_text)

    result = []
    for c in canonicals:
        names = {c.canonical_name, c.display_name, *aliases.get(c.id, set())} - {None}
        result.append({
            "canonical_name": c.canonical_name,
            "display_name": c.display_name,
            "mbid": c.mbid,
            "aliases": sorted(names),
            "itunes_artist_id": c.itunes_artist_id,
            "anchor_confirmed_by": c.anchor_confirmed_by,
            "concert_count": sum(text_counts.get(n, 0) for n in names),
        })
    result.sort(key=lambda a: -a["concert_count"])
    return result


async def _export_real_setlists() -> list[dict]:
    async with AsyncSessionLocal() as db:
        rows = await db.execute(
            select(RealSetlist, Concert)
            .join(Concert, Concert.id == RealSetlist.concert_id)
            .where(func.jsonb_array_length(RealSetlist.songs) > 0)
            .order_by(RealSetlist.performance_date)
        )
        return [
            {
                "concert_id": str(rs.concert_id),
                "performance_date": rs.performance_date.isoformat(),
                "artist_names": concert.artist_name or [],
                "event_type": concert.event_type,
                "setlistfm_id": rs.setlistfm_id,
                "is_user_edited": rs.is_user_edited,
                "songs": rs.songs,
            }
            for rs, concert in rows.all()
        ]


async def main() -> None:
    _OUT_DIR.mkdir(exist_ok=True)
    artists = await _export_artists()
    real_setlists = await _export_real_setlists()
    (_OUT_DIR / "artist_candidates.json").write_text(json.dumps(artists, ensure_ascii=False, indent=1), "utf-8")
    (_OUT_DIR / "real_setlists.json").write_text(json.dumps(real_setlists, ensure_ascii=False, indent=1), "utf-8")
    print(f"artist_candidates {len(artists)}건, real_setlists {len(real_setlists)}건 -> {_OUT_DIR}")
    await engine.dispose()


if __name__ == "__main__":
    asyncio.run(main())
