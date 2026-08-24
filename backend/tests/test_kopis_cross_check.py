# kopis_cross_check.py의 순수 비교 로직만 단위 테스트 (DB/네트워크 불필요).
# KOPIS 재조회 자체는 kopis.py의 기존 _fetch_kopis_detail_data를 그대로 재사용하므로 여기서
# 따로 검증하지 않음.

from scripts.kopis_cross_check import _is_covered


def test_covered_when_name_in_title():
    assert _is_covered("브로콜리너마저", "어슬렁 어슬렁 콘서트: 브로콜리너마저", []) is True


def test_covered_when_name_matches_kopis_cast():
    assert _is_covered("박성규", "단독 콘서트", ["박성규"]) is True


def test_covered_when_kopis_cast_has_extra_formatting():
    # KOPIS쪽이 "존박(박성규)"처럼 부가정보를 붙여도 부분포함으로 커버
    assert _is_covered("박성규", "단독 콘서트", ["존박(박성규)"]) is True


def test_covered_via_romanization_against_kopis_cast():
    # 제목/KOPIS 원문 비교로는 안 걸려도 한글<->로마자 표기 차이는 커버 (실제 회귀:
    # docs/artist_extraction_bugs.md 패턴7, PF297474 "KIM SIHUN")
    assert _is_covered("김시훈", "concert title", ["Kim Sihun"]) is True


def test_flagged_when_misread_name_differs_from_correct_kopis_cast():
    # 실제 오독 버그 재현: 포스터를 잘못 읽어 "김시현"으로 뽑았지만 KOPIS 원본은 "김시훈"
    assert _is_covered("김시현", "KIM SIHUN ASIA TOUR", ["김시훈"]) is False


def test_flagged_when_neither_source_has_the_name():
    assert _is_covered("완전히없는이름", "다른 공연 제목", ["실제아티스트"]) is False


def test_empty_name_treated_as_covered():
    assert _is_covered("", "아무 제목", []) is True
