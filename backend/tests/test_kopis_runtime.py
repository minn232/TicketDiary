import pytest

from app.services.kopis import _parse_runtime_minutes


# KOPIS 러닝타임 문자열을 분으로 변환(서버 샘플에서 확인한 형식들 + 변형)
@pytest.mark.parametrize(
    "raw, expected",
    [
        ("2시간", 120),
        ("1시간 30분", 90),
        ("1시간30분", 90),
        ("2 시간 30 분", 150),
        ("90분", 90),
        ("6시간 15분", 375),
        ("1시간 30분(인터미션 20분 포함)", 90),
        ("", None),
        (None, None),
        ("미정", None),
        ("0분", None),
    ],
)
def test_parse_runtime_minutes(raw, expected):
    assert _parse_runtime_minutes(raw) == expected
