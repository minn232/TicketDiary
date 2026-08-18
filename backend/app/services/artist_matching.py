import re

from rapidfuzz import fuzz, process, utils
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.concert import Concert

# 이 이상 유사하면 같은 아티스트로 보고 기존 표기를 재사용 (0~100 스케일)
# 공백/오탈자/대소문자 정도의 흔들림만 흡수하려는 목적이라 다소 보수적으로 높게 잡음
_FUZZY_MATCH_THRESHOLD = 92

# 한글 음절 로마자 변환표 (표준 로마자 표기법). 받침 뒤 연음 등 정밀 규칙은 생략한
# 근사치 - 사람이 읽을 표기가 아니라 퍼지매칭 전처리 전용이라 정확한 표기법일 필요는 없음
_HANGUL_BASE = 0xAC00
_HANGUL_END = 0xD7A3
_INITIALS = ["g", "kk", "n", "d", "tt", "r", "m", "b", "pp", "s", "ss", "", "j", "jj", "ch", "k", "t", "p", "h"]
_MEDIALS = [
    "a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa", "wae", "oe",
    "yo", "u", "wo", "we", "wi", "yu", "eu", "ui", "i",
]
_FINALS = [
    "", "k", "k", "k", "n", "n", "n", "t", "l", "k", "m", "l", "l", "l", "l",
    "l", "m", "p", "p", "t", "t", "ng", "t", "t", "k", "t", "p", "t",
]

# 실제 활동명/인명 표기에서 흔한 통용 표기(김→Kim, 현→Hyun, 정→Jung처럼 표준표기와 다른 경우가
# 많음) - 초성 ㄱ, 중성 ㅓ/ㅕ만 통용 표기로 바꾼 두 번째 변환표를 따로 두고 둘 다 시도한다
_INITIALS_INFORMAL = list(_INITIALS)
_INITIALS_INFORMAL[0] = "k"  # ㄱ
_MEDIALS_INFORMAL = list(_MEDIALS)
_MEDIALS_INFORMAL[4] = "u"  # ㅓ
_MEDIALS_INFORMAL[6] = "yu"  # ㅕ

# 로마자 변환 경유 매칭 임계치. 오히려 원문 매칭보다 더 보수적으로 잡아야 함 - 한글을
# 로마자로 펼치면 글자 수가 늘어나서(예: "아티스트" 4자 -> "atiseuteu" 9자) 끝 글자 하나만
# 다른 두 이름(예: "아티스트A"/"아티스트B")의 유사도가 원문 비교 때보다 부풀려짐(80% -> 90%)
# - 실측(테스트)으로 확인된 문제라 _FUZZY_MATCH_THRESHOLD(92)보다 오히려 높게 잡음
_ROMANIZATION_MATCH_THRESHOLD = 95


def _contains_hangul(text: str) -> bool:
    return any(_HANGUL_BASE <= ord(ch) <= _HANGUL_END for ch in text)


def _romanize(text: str, initials: list[str], medials: list[str]) -> str:
    out = []
    for ch in text:
        code = ord(ch) - _HANGUL_BASE
        if 0 <= code < 11172:
            initial, rem = divmod(code, 21 * 28)
            medial, final = divmod(rem, 28)
            out.append(initials[initial] + medials[medial] + _FINALS[final])
        else:
            out.append(ch)
    return "".join(out)


# 한글이 섞인 이름의 로마자 변환 후보 두 개(표준/통용) 반환, 한글이 없으면 빈 리스트
def _romanized_variants(text: str) -> list[str]:
    if not _contains_hangul(text):
        return []
    return [_romanize(text, _INITIALS, _MEDIALS), _romanize(text, _INITIALS_INFORMAL, _MEDIALS_INFORMAL)]


_NON_ALNUM_RE = re.compile(r"[^0-9a-z가-힣]+")


# 로마자 변환 결과엔 공백이 없는데("김현정" -> "gimhyeonjeong") known 쪽 원문엔 공백이 있는
# 경우가 많아서(예: "Jin Hyeon Jun") utils.default_process만으론 공백 차이가 유사도를 깎는다.
# 공백/기호를 아예 없애고 비교(rapidfuzz의 default_process는 공백을 유지함)
def _compact(text: str) -> str:
    return _NON_ALNUM_RE.sub("", text.lower())


# 한글 이름의 로마자 변환 후보를 known_names(로마자 변환 필요하면 마찬가지로 변환)와 비교해
# 원문 매칭(normalize_artist_names의 1차 패스)에서 놓친 한글/로마자 표기 쌍을 찾는다.
# 예: "김현정" ↔ "Kim Hyunjung" - 방탄소년단↔BTS처럼 의미가 다른 별칭은 여전히 못 잡음
def _romanization_match(name: str, known_names: set[str]) -> str | None:
    name_has_hangul = _contains_hangul(name)
    name_variants = _romanized_variants(name) if name_has_hangul else [name]

    best_score, best_match = 0, None
    for known in known_names:
        known_has_hangul = _contains_hangul(known)
        if not name_has_hangul and not known_has_hangul:
            continue  # 둘 다 한글이 아니면 이 함수가 할 일이 없음(원문 매칭에서 이미 처리됨)
        known_variants = _romanized_variants(known) if known_has_hangul else [known]
        for a in name_variants:
            for b in known_variants:
                score = fuzz.ratio(_compact(a), _compact(b))
                if score > best_score:
                    best_score, best_match = score, known

    return best_match if best_score >= _ROMANIZATION_MATCH_THRESHOLD else None


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


# 새 아티스트명들을 기존 DB의 유사 표기와 매칭해 정규화(공백/오탈자/대소문자 흔들림만 흡수) -
# 한글/영문처럼 스크립트가 완전히 다른 별칭("방탄소년단" vs "BTS")은 문자열 유사도로 못 잡는
# 알려진 한계라 자동화 대상 아님. known_names를 넘기면 재조회 없이 재사용(배치 호출용),
# 없으면 빈 집합에서 시작.
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
            # 원문 그대로는 안 맞았지만 한글↔로마자 표기 차이일 수 있으니 한 번 더 시도
            romanized = _romanization_match(name, known_names) if known_names else None
            canonical = romanized or name
            if romanized is None:
                known_names.add(name)

        normalized.append(canonical)
    return normalized


# 기존 아티스트명에 새로 확인된 이름들을 합집합으로 병합 (덮어쓰지 않음). 크롤링/포스터 추출 두
# 경로가 서로 다른 시점에 아티스트를 채울 수 있고, 페스티벌은 1차/2차/3차로 시간차를 두고
# 라인업이 늘어나므로 먼저 채워진 이름을 지우지 않고 새 이름만 더하는 방식이 맞음
#
# replace=True면 합집합 대신 incoming으로 통째로 교체 - KOPIS 원본(prfcast)이 활동명 대신
# 본명/멤버명을 주는 경우가 많아서(예: 존박→박성규), 소규모(단독 추정) 공연에 한해 더 신뢰할
# 수 있는 포스터 쪽 결과가 오면 KOPIS 표기를 밀어내기 위한 것 - 호출부가 "소규모+KOPIS
# 원본"인지 판단해서 넘겨줌 (라인업이 많은 페스티벌엔 적용 안 해야 데이터 유실이 없음)
def merge_artist_names(
    existing: list[str] | None,
    incoming: list[str],
    known_names: set[str] | None = None,
    *,
    replace: bool = False,
) -> list[str]:
    normalized_incoming = normalize_artist_names(incoming, known_names)
    if replace:
        return sorted(set(normalized_incoming))
    return sorted(set(existing or []) | set(normalized_incoming))
