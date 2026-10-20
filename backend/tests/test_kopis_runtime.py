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


# KOPIS 방화벽이 정상 요청도 무작위로 400(Request Blocked)을 주므로, 400이면 잠깐 쉬고 재시도해서
# 다음 응답을 쓰는지 테스트 (재시도 대기는 0으로 패치)
@pytest.mark.asyncio
async def test_kopis_get_retries_on_blocked_400():
    from unittest.mock import AsyncMock, MagicMock, patch
    from app.services import kopis

    blocked, ok = MagicMock(status_code=400), MagicMock(status_code=200)
    client = MagicMock()
    client.get = AsyncMock(side_effect=[blocked, ok])

    with patch.object(kopis, "_KOPIS_BLOCKED_RETRY_DELAY", 0):
        response = await kopis._kopis_get(client, "prfplc", {"shprfnmfct": "킨텍스"})

    assert response is ok
    assert client.get.call_count == 2
