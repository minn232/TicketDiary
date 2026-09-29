from datetime import date, timedelta

from app.services.setlist_model import (
    ModelParams,
    ModelShow,
    confidence_label,
    normalize_title,
    predict_setlist,
    shows_from_setlistfm,
)

_TODAY = date(2026, 9, 1)


# 최신순 이력 만들기 - shows[0]이 가장 최근, 공연 사이 간격은 7일
def _history(*song_lists: list[str], tour: str | None = None) -> list[ModelShow]:
    return [ModelShow(_TODAY - timedelta(days=7 * i), tour, songs) for i, songs in enumerate(song_lists)]


def _names(result: list[dict]) -> list[str]:
    return [s["name"] for s in result]


# Setlist.fm 응답 변환

def test_shows_from_setlistfm_parses_sorts_and_drops_tape():
    raw = [
        {"eventDate": "01-02-2025", "sets": {"set": [{"song": [{"name": " A "}, {"name": "인트로", "tape": True}]}]}},
        {"eventDate": "03-04-2025", "tour": {"name": "투어"}, "sets": {"set": [{"song": [{"name": "B"}]}]}},
        {"eventDate": "잘못된날짜", "sets": {"set": [{"song": [{"name": "C"}]}]}},
        {"sets": {"set": []}},
    ]
    shows = shows_from_setlistfm(raw)

    assert [s.date for s in shows] == [date(2025, 4, 3), date(2025, 2, 1)]
    assert shows[0].tour == "투어" and shows[1].tour is None
    assert shows[1].songs == ["A"]


def test_confidence_label_thresholds():
    assert [confidence_label(p) for p in (0.95, 0.9, 0.7, 0.6, 0.59, 0.1)] == [
        "high", "high", "likely", "likely", "possible", "possible"
    ]


def test_normalize_title_ignores_case_symbols_and_parentheses_but_keeps_non_latin():
    assert normalize_title("Good Day (Live)") == normalize_title("good  day!")
    assert normalize_title("잔인한 사월") != normalize_title("잔인한 4월")
    assert normalize_title("マリーゴールド") == "マリーゴールド"


# 예측

def test_predict_returns_empty_without_usable_shows():
    assert predict_setlist([]) == []
    assert predict_setlist(_history(["A", "B"])) == []  # 곡 3개 미만 셋리는 불량으로 제외


def test_recent_songs_rank_above_old_songs():
    # 옛 곡 3개는 오래된 5공연에만, 새 곡 3개는 최근 5공연에만 나옴 - 빈도는 같지만 최근성으로 갈림
    recent = ["새1", "새2", "새3"]
    old = ["옛1", "옛2", "옛3"]
    result = predict_setlist(_history(*[recent] * 5, *[old] * 5), estimate_length=False, order=False)

    names = _names(result)
    assert set(names[:3]) == set(recent)
    assert {s["name"]: s["probability"] for s in result}["새1"] > {s["name"]: s["probability"] for s in result}["옛1"]


def test_single_show_probability_is_smoothed_below_one():
    result = predict_setlist(_history(["A", "B", "C"]))
    assert all(0.15 < s["probability"] < 1 for s in result)


def test_length_estimate_follows_recent_show_lengths_not_fixed_20():
    songs = [f"곡{i}" for i in range(12)]
    result = predict_setlist(_history(*[songs] * 6))
    assert len(result) == 12


def test_low_probability_songs_dropped():
    # 최근 8공연 중 마지막 하나에만 한 번 나온 곡은 확률이 하한 아래로 떨어져 빠짐
    core = ["A", "B", "C", "D", "E", "F"]
    result = predict_setlist(_history(*[core] * 8, [*core, "가끔곡"]))
    assert "가끔곡" not in _names(result)


def test_order_follows_fixed_running_order():
    running_order = ["오프닝", "둘째", "셋째", "넷째", "다섯째", "엔딩"]
    result = predict_setlist(_history(*[running_order] * 6))
    assert _names(result) == running_order


def test_order_uses_average_position_when_orders_vary():
    shows = _history(
        ["오프닝", "중간1", "중간2", "엔딩"], ["오프닝", "중간2", "중간1", "엔딩"], ["오프닝", "중간1", "중간2", "엔딩"],
        ["오프닝", "중간2", "중간1", "엔딩"], ["오프닝", "중간1", "중간2", "엔딩"], ["오프닝", "중간2", "중간1", "엔딩"],
    )
    names = _names(predict_setlist(shows))
    assert names[0] == "오프닝" and names[-1] == "엔딩"


def test_max_songs_caps_result_for_guest_slots():
    songs = [f"곡{i}" for i in range(12)]
    params = ModelParams(max_songs=5, min_songs=5)
    result = predict_setlist(_history(*[songs] * 6), "short", params)
    assert len(result) == 5


def test_target_form_downweights_other_form_shows():
    # 짧은 공연(페스티벌)에서만 하던 곡은 단독(full) 예측에선 밀리고 short 예측에선 올라옴
    full_set = [f"본공연{i}" for i in range(10)]
    short_set = ["짧은1", "짧은2", "짧은3"]
    history = _history(*[short_set] * 3, *[full_set] * 3)
    as_full = predict_setlist(history, "full", order=False)
    as_short = predict_setlist(history, "short", order=False)

    assert not (set(short_set) & set(_names(as_full)[:3]))
    assert set(_names(as_short)[:3]) == set(short_set)


def test_prediction_is_deterministic():
    songs = [f"곡{i}" for i in range(8)]
    history = _history(*[songs] * 4, list(reversed(songs)))
    assert predict_setlist(history) == predict_setlist(history)
