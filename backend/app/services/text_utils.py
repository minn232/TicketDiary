import re

_HANGUL_ONLY_RE = re.compile(r"^[가-힣]+$")


# LIKE/ILIKE 패턴에 넣을 사용자 입력의 와일드카드(%, _)를 문자 그대로 매치하도록 이스케이프
# (쓰는 쪽은 escape="\\"를 같이 넘겨야 함)
def escape_like(s: str) -> str:
    return s.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


# 한글은 음절당 정보 밀도가 높아 2글자도 유의미한 단어(예: "빨래")인 경우가 많은 반면,
# 로마자 2글자는 흔한 조각(예: "HA")이라 오탐 위험이 커서 최소 3글자를 요구
def min_len_ok(s: str) -> bool:
    return len(s) >= (2 if _HANGUL_ONLY_RE.fullmatch(s) else 3)
