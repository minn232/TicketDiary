from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.artist_blocklist import BlockedArtistName

# LLM이 아티스트 자리에 반복적으로 잘못 뽑아내는 것으로 "확정된" 브랜드/페스티벌/공연장명을
# 저장 직전에 한 번 더 거르는 안전망 - normalize.py의 FESTIVAL+1 필터(event_type 분류가
# 맞아야만 작동, 오탐도 있음)와 달리 event_type과 무관하게 "이 문자열은 늘 아티스트가 아님"이
# 사람 검증으로 확정된 것만 정밀 매칭한다(새 케이스 발견용이 아니라 재발 방지용).
# 출처: docs/artist_extraction_bugs.md 패턴 1/2/3, 실제 포스터 대조로 확정된 것만 담음.
# 확장: 같은 문자열이 반복 오인되면 추가, 한 번만 나온 애매한 케이스는 넣지 않음(exact match라
# 그 이름을 실제로 쓰는 신인 아티스트가 나중에 생길 가능성을 고려해 신중히 유지보수).
BLOCKLISTED_ARTIST_NAMES: set[str] = {
    # 패턴 1: 페스티벌/이벤트 브랜드명 (docs/artist_extraction_bugs.md 패턴1, 18건 확정)
    "SOUNDBERRY",
    "MIYAKO",
    "JUMF",
    "MyK",
    "KIMCHIKURA",
    "라움",
    "OBJET K-POP",
    "NOL",
    "NOL FESTIVAL",
    "Peaches",
    "GHOST",
    "광주 소극장 재즈페스티벌",
    "ING",
    "송도 트라이보울 재즈 페스티벌",
    # few-shot v2 재검증에서 추가 확인된 브랜드명 - FESTIVAL+1 구조적 필터가 우연히
    # 같이 잡아주고 있었을 뿐 별도 확정 필요
    "S2O Korea",
    "카스쿨",
    # 패턴 2: placeholder 할루시네이션 (docs/artist_extraction_bugs.md 패턴2, 3건 확정) -
    # llm_server/normalize.py의 _NULL_LITERALS엔 "null"/"none"류만 있고 이건 안 걸러짐
    "Various Artists",
    # 패턴 3: 공연장/시설명이 아티스트 자리에 혼입 (docs/artist_extraction_bugs.md 패턴3, 확정분만)
    "영등포아트홀",
    "ZOMBIE CRAB LABO",
    "TIGER DOME",
    "고려대학교 화정체육관",
}

def _normalize(name: str) -> str:
    return " ".join(name.split()).casefold()


# 위 코드 블록리스트는 배포해야만 반영되는 "검토된" 목록. 관리자 페이지에서 즉시 추가하는
# 것들은 DB(BlockedArtistName)에 쌓이고, 이 인메모리 집합에 합쳐져서 배포 없이 바로
# 적용된다 - 앱 시작 시 한 번(refresh_blocklist_cache) + 추가할 때마다(add_to_blocklist) 갱신
_dynamic_blocklist: set[str] = set()
_NORMALIZED_BLOCKLIST: set[str] = {_normalize(name) for name in BLOCKLISTED_ARTIST_NAMES}


# 공백 흔들림/대소문자만 다른 재발도 잡히게 정규화 후 비교 (오탈자·부분일치까지 잡을 필요는
# 없음 - 확정된 것만 정밀 타격하는 게 목적이라 exact match 유지)
def is_blocklisted_artist_name(name: str) -> bool:
    return _normalize(name) in _NORMALIZED_BLOCKLIST


# 앱 시작 시 DB에 쌓인 관리자 추가분을 인메모리 캐시로 불러옴 (lifespan에서 1회 호출)
async def refresh_blocklist_cache(db: AsyncSession) -> None:
    global _dynamic_blocklist, _NORMALIZED_BLOCKLIST
    names = (await db.execute(select(BlockedArtistName.name))).scalars().all()
    _dynamic_blocklist = {_normalize(name) for name in names}
    _NORMALIZED_BLOCKLIST = {_normalize(name) for name in BLOCKLISTED_ARTIST_NAMES} | _dynamic_blocklist


# 관리자 페이지에서 호출 - DB에 영구 저장하고 인메모리 캐시도 즉시 갱신(재배포/재시작 없이
# 바로 다음 요청부터 차단됨). 이미 있는 이름이면 조용히 스킵
async def add_to_blocklist(db: AsyncSession, name: str, source: str = "admin") -> None:
    global _NORMALIZED_BLOCKLIST
    name = name.strip()
    if not name or is_blocklisted_artist_name(name):
        return
    db.add(BlockedArtistName(name=name, source=source))
    await db.commit()
    _dynamic_blocklist.add(_normalize(name))
    _NORMALIZED_BLOCKLIST = {_normalize(n) for n in BLOCKLISTED_ARTIST_NAMES} | _dynamic_blocklist
