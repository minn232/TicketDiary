import pytest

from app.schemas.concert import ConcertSummary, display_venue


# 괄호 안이 앞부분과 같은 공연장명만 괄호를 빼는지 테스트
@pytest.mark.parametrize(
    "raw, expected",
    [
        ("예스24 라이브홀 (예스24라이브홀)", "예스24 라이브홀"),
        ("YES24 LIVE HALL (yes24 live hall)", "YES24 LIVE HALL"),
        ("블루스퀘어(블루스퀘어)", "블루스퀘어"),
        ("올림픽공원 (올림픽홀)", "올림픽공원 (올림픽홀)"),
        ("올림픽공원 (KSPO DOME(체조경기장))", "올림픽공원 (KSPO DOME(체조경기장))"),
        ("(A)", "(A)"),
        ("", ""),
        (None, None),
    ],
)
def test_display_venue(raw, expected):
    assert display_venue(raw) == expected


# 응답 스키마에서 자동으로 정리되는지 테스트
def test_concert_summary_venue_cleaned():
    summary = ConcertSummary(
        id="00000000-0000-0000-0000-000000000001", kopis_id=None, name="공연", artist_name=[],
        venue="블루스퀘어 (블루스퀘어)", start_date="2026-11-01T00:00:00Z", start_time=None,
        end_date="2026-11-01T00:00:00Z", genre=None, poster_url=None, event_type="SOLO",
        ticketing_date=None, delivery_date=None,
    )
    assert summary.venue == "블루스퀘어"
