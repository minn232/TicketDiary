from rapidfuzz import fuzz, process, utils
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.concert import Concert

# 이 이상 유사하면 같은 아티스트로 보고 기존 표기를 재사용 (0~100 스케일)
# 공백/오탈자/대소문자 정도의 흔들림만 흡수하려는 목적이라 다소 보수적으로 높게 잡음
_FUZZY_MATCH_THRESHOLD = 92


# DB에 이미 존재하는 distinct 아티스트명 집합 조회
# (배치로 여러 건을 정규화할 때 한 번만 구축해서 재사용하기 위함 - _build_follow_index와 같은 목적)
async def get_known_artist_names(db: AsyncSession) -> set[str]:
    result = await db.execute(select(Concert.artist_name).where(Concert.artist_name != []))
    names: set[str] = set()
    for arr in result.scalars().all():
        for name in (arr or []):
            if name and name.strip():
                names.add(name.strip())
    return names


# 새 아티스트명들을 기존 DB의 유사 표기와 매칭해 정규화 (공백/오탈자/대소문자 정도의 흔들림만 흡수 -
# 한글/영문처럼 스크립트가 완전히 다른 별칭(예: "방탄소년단" vs "BTS")은 문자열 유사도로 못 잡는
# 알려진 한계가 있음, 이 경우는 자동화 대상이 아니라 확인 필요 케이스로 남겨둠
#
# known_names를 넘기면 재조회 없이 재사용하고 새로 확정된 이름을 그 자리에서 추가함(배치 호출용),
# 없으면 단발 호출로 간주해 빈 집합에서 시작함
def normalize_artist_names(names: list[str], known_names: set[str] | None = None) -> list[str]:
    if known_names is None:
        known_names = set()

    normalized: list[str] = []
    for raw_name in names:
        name = raw_name.strip()
        if not name:
            continue

        match = (
            process.extractOne(name, known_names, scorer=fuzz.ratio, processor=utils.default_process)
            if known_names
            else None
        )
        if match is not None and match[1] >= _FUZZY_MATCH_THRESHOLD:
            canonical = match[0]
        else:
            canonical = name
            known_names.add(name)

        normalized.append(canonical)
    return normalized
