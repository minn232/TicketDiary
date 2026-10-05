"""신규등록/수정이 무관한 기존 canonical로 조용히 흡수되는 버그 원인 조사용 - 실제
canonical_names 3천여개 기준으로 normalize_artist_names가 어떤 이름과 왜 매치되는지 직접 확인.
읽기 전용, DB 변경 없음.
"""
import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from sqlalchemy import select  # noqa: E402
from rapidfuzz import fuzz, process, utils  # noqa: E402

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.artist_normalization import CanonicalArtist  # noqa: E402
from app.services.artist_matching import normalize_artist_names, _romanization_match, _FUZZY_MATCH_THRESHOLD  # noqa: E402


async def main():
    async with AsyncSessionLocal() as db:
        result = await db.execute(select(CanonicalArtist.canonical_name))
        canonical_names = {n for n in result.scalars().all() if n}

    print(f"canonical_names 총 {len(canonical_names)}개, threshold={_FUZZY_MATCH_THRESHOLD}")

    for query in ["김정균", "김중연", "JAEHA"]:
        print(f"\n=== query={query!r} ===")
        match = process.extractOne(query, canonical_names, scorer=fuzz.ratio, processor=utils.default_process)
        print(f"fuzz.ratio best match: {match}")
        romanized = _romanization_match(query, canonical_names)
        print(f"romanization match: {romanized!r}")
        resolved = normalize_artist_names([query], set(canonical_names))[0]
        print(f"normalize_artist_names resolved -> {resolved!r}")
        print(f"exact in canonical_names: {query in canonical_names}")


if __name__ == "__main__":
    asyncio.run(main())
