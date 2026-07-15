# 예매 사이트 사명 변경/표기 흔들림에 대응하는 단일 별칭 테이블.
# kopis.py(relatenm 자유 텍스트 매칭)와 crawler.py(ticketing_site 필드 정규화)가
# 각자 다른 테이블을 따로 유지하다 새 별칭이 한쪽에만 추가되어 어긋나는 것을 막기 위해 통합함.
# 인터파크가 2023년경 "NOL 티켓"으로 리브랜딩했으나 티켓 발급 시점에 따라 구/신 표기가 섞여 들어옴.
SITE_ALIASES: dict[str, str] = {
    "yes24": "YES24",
    "예스24": "YES24",
    "인터파크": "INTERPARK",
    "interpark": "INTERPARK",
    "nol": "INTERPARK",
    "nol티켓": "INTERPARK",
    "nolticket": "INTERPARK",
    "놀유니버스": "INTERPARK",  # KOPIS relatenm이 서비스명(NOL) 대신 운영사명(놀유니버스)으로 오는 경우
    "티켓링크": "TICKETLINK",
    "ticketlink": "TICKETLINK",
    "멜론티켓": "MELON",
    "멜론": "MELON",
    "melon": "MELON",
}


def _normalize_key(name: str) -> str:
    return name.strip().lower().replace(" ", "")


# ticketing_site처럼 "이 문자열 자체가 사이트 표기"인 값을 대표 키로 정규화
# (일치하는 별칭이 없으면 대문자로 정규화한 원본을 그대로 반환)
def normalize_site_key(name: str) -> str:
    key = _normalize_key(name)
    return SITE_ALIASES.get(key, name.strip().upper())


# relatenm처럼 "사이트 표기가 포함된 자유 텍스트"에서 부분일치로 대표 키를 찾음 (없으면 None)
def find_site_key(text: str) -> str | None:
    normalized = _normalize_key(text)
    for key, value in SITE_ALIASES.items():
        if key in normalized:
            return value
    return None
