# LLM이 아티스트 자리에 반복적으로 잘못 뽑아내는 것으로 "확정된" 브랜드/페스티벌/공연장명을
# 저장 직전에 한 번 더 거르는 안전망. normalize.py(llm_server)의 FESTIVAL+1 구조적 필터
# (event_type=FESTIVAL인데 이름이 1개뿐이면 버림)와는 다른 층위 - 그쪽은 event_type 분류가
# 맞아야만 작동하고 오탐도 있음(단독공연이 FESTIVAL로 잘못 태깅되면 진짜 정답까지 지움), 이건
# event_type과 무관하게 "이 문자열 자체가 늘 아티스트가 아님"이 사람 검증으로 확정된 것만
# 정밀 매칭한다. 새 케이스를 발견하는 용도가 아니라, 이미 아는 오탐의 재발만 막는 용도.
#
# 출처: docs/artist_extraction_bugs.md 패턴 1(브랜드명 오인)/2(placeholder 할루시네이션)/
# 3(공연장명 혼입), 실제 포스터 대조로 확정된 것만 담는다 - 의심만 되는 건 넣지 말 것.
#
# 확장 방법: 새 배치 재검증(예: test_concerts_v2_remaining.csv 511건)에서 같은 문자열이
# 다른 공연에서도 반복 오인되는 게 확인되면 여기 추가. 한 번만 나온 애매한 케이스는 넣지 않음
# (오탐으로 진짜 아티스트명을 지울 위험) - exact match라 부분 문자열 오염과는 무관하지만,
# 그 이름을 실제로 쓰는 신인 아티스트가 나중에 생길 가능성은 항상 있으므로 신중하게 유지보수.
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
    # few-shot v2 재검증([[artist_extraction_fewshot_v2_verification_2026-08-24]])에서 추가
    # 확인된 브랜드명 - FESTIVAL+1 구조적 필터가 우연히 같이 잡아주고 있었을 뿐 별도 확정 필요
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

_NORMALIZED_BLOCKLIST: set[str] = {" ".join(name.split()).casefold() for name in BLOCKLISTED_ARTIST_NAMES}


# 공백 흔들림/대소문자만 다른 재발도 잡히게 정규화 후 비교 (오탈자·부분일치까지 잡을 필요는
# 없음 - 확정된 것만 정밀 타격하는 게 목적이라 exact match 유지)
def is_blocklisted_artist_name(name: str) -> bool:
    return " ".join(name.split()).casefold() in _NORMALIZED_BLOCKLIST
