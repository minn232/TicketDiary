import re
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.artist_normalization import ArtistAlias
from app.services.artist_identity import resolve_concert_artist

# 공연명에서 "여기부터는 게스트"를 뜻하는 표기 (X/x/&는 동등 출연이라 여기에 없음)
_GUEST_MARKER = re.compile(r"\bwith\b|\bfeat\.?|\bft\.|\bguest\b|게스트|특별출연|스페셜\s*게스트", re.IGNORECASE)
_MIN_NAME_LENGTH = 2


def _norm(text: str) -> str:
    return re.sub(r"\W", "", text.casefold())


# 공연명에 이름(별칭 포함)이 들어있는 아티스트의 인덱스 - 게스트 표기(with/feat/Guest) 뒤에 나온 이름은
# 게스트로 뺌. 이름이 하나도 안 나오면 None(판단 불가). 백테스트(43건)에서 정확일치 0.76 / 주인공 포함 0.94
def pick_headliners(concert_name: str, name_variants: list[set[str]]) -> set[int] | None:
    marker = _GUEST_MARKER.search(concert_name)
    full_title = _norm(concert_name)
    head_title = _norm(concert_name[: marker.start()]) if marker else full_title
    names = [{n for n in (_norm(x) for x in variants) if len(n) >= _MIN_NAME_LENGTH} for variants in name_variants]

    found = {i for i, ns in enumerate(names) if any(n in full_title for n in ns)}
    if not found:
        return None
    if marker:
        before = {i for i in found if any(n in head_title for n in names[i])}
        if before:
            return before
    return found


# 공연 아티스트별 이름 표기 모음 - 표기 자체 + 확정된 canonical의 이름/표시명/별칭(공연명이 다른 언어
# 표기로 적힌 경우를 잡으려고). 공연별 연결(유저 수정)이 있으면 그 canonical 기준
async def load_name_variants(db: AsyncSession, concert_id: UUID | None, artists: list[str]) -> list[set[str]]:
    variants = []
    for artist in artists:
        names = {artist}
        canonical, _ = await resolve_concert_artist(db, concert_id, artist)
        if canonical is not None:
            names |= {canonical.canonical_name, canonical.display_name} - {None}
            alias_rows = await db.execute(
                select(ArtistAlias.alias_text).where(ArtistAlias.canonical_artist_id == canonical.id)
            )
            names |= set(alias_rows.scalars().all())
        variants.append(names)
    return variants
