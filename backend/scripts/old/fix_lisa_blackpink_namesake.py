"""LiSA(일본 애니송 가수) 콘서트가 블랙핑크 Lisa로 오매칭돼있던 실사례 1회성 수정.
[[admin_canonical_reassignment_gap_2026-09-07]] 참고 - 텍스트는 정확히 같은데 실존 인물이
다른 동명이인 케이스라 reassign_artist_to_canonical로 강제 재지정해야만 고쳐짐.

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/old/fix_lisa_blackpink_namesake.py
"""

import asyncio
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

import httpx  # noqa: E402

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.artist_normalization import CanonicalArtist  # noqa: E402
from app.services.artist_normalization import (  # noqa: E402
    get_or_create_canonical_by_mbid,
    register_artist_image,
    register_wikidata_korean_alias,
    reassign_artist_to_canonical,
)

# MusicBrainz에서 실측 확인한 값(country:JP, disambiguation="Japanese pop/rock singer",
# 본명 織部里沙/Risa Oribe) - 블랙핑크 Lisa(country:KR, disambiguation="BLACKPINK")와는 별개 mbid
_REAL_LISA_MBID = "85d76093-9865-4605-97fa-8c910929d366"
_CONCERT_ID = "260698e5-8325-4b62-a50e-ba3f28b82c12"
_ARTIST_TEXT = "LISA"


async def main() -> None:
    async with AsyncSessionLocal() as db:
        canonical, created = await get_or_create_canonical_by_mbid(db, _REAL_LISA_MBID, "LiSA")
        await db.commit()
        canonical_id = canonical.id
        print(f"canonical: id={canonical_id} created={created}")

    async with httpx.AsyncClient(timeout=10.0) as client:
        async with AsyncSessionLocal() as db:
            canonical = await db.get(CanonicalArtist, canonical_id)
            await register_wikidata_korean_alias(db, canonical, client)
            await register_artist_image(db, canonical, client)
            await db.commit()
            print(f"display_name={canonical.display_name} profile_image_url={canonical.profile_image_url}")

    async with AsyncSessionLocal() as db:
        concert = await reassign_artist_to_canonical(db, uuid.UUID(_CONCERT_ID), _ARTIST_TEXT, canonical_id)
        print(f"concert.artist_name = {concert.artist_name}")


if __name__ == "__main__":
    asyncio.run(main())
