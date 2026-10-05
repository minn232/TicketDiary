"""예상 셋리 백테스트 실행 - 예측기별로 정답 공연을 얼마나 맞추는지 비교.

캐시(cache/)만 읽음(API/DB 호출 없음). 예측기는 predict(case) -> 곡명 리스트(순서 = 예측 순서)이고
case.history에는 정답 날짜 이전 공연만 들어있음(data.split_cases 참고).

사용법 (backend/에서):
    python scripts/backtest/run_backtest.py                 # 등록된 예측기 전부
    python scripts/backtest/run_backtest.py --only A0       # 일부만
    python scripts/backtest/run_backtest.py --verify-a0     # A0가 운영 코드와 같은 결과인지 검증
"""

import argparse
import asyncio
import json
import sys
from collections import Counter
from itertools import combinations
from pathlib import Path
from statistics import mean

_BACKEND_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_BACKEND_ROOT))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from app.services.setlist_model import (  # noqa: E402
    ModelParams,
    ModelShow,
    classify_length,
    predict_setlist,
)
from data import LIVE_HISTORY_SHOWS, Case, load_all_artists, split_cases, title_key  # noqa: E402

_RESULT_DIR = Path(__file__).resolve().parent / "results"


# A0 - 현재 운영 방식: 최근 60공연(곡 없는 공연 포함)에서 곡명(lower) 빈도 top20, 빈도순
def predict_a0(case: Case, top_n: int = 20) -> list[str]:
    counts: Counter = Counter()
    display: dict[str, str] = {}
    for show in case.history[:LIVE_HISTORY_SHOWS]:
        for song in show.songs:
            key = song["name"].lower()
            counts[key] += 1
            display.setdefault(key, song["name"])
    return [display[key] for key, _ in counts.most_common(top_n)]


# 대상 공연 형태: full = 항상 단독공연으로 가정 / oracle = 정답 곡 수로 판정(운영에선 event_type으로 아는
# 정보의 대용이지만 정답을 들여다보는 셈이라 낙관적임)
FORM_MODE = "full"
PARAMS = ModelParams()


def _model_history(case: Case) -> list[ModelShow]:
    return [
        ModelShow(date=s.date, tour=s.tour, songs=[x["name"] for x in s.songs if not x["tape"]])
        for s in case.history[:LIVE_HISTORY_SHOWS]
    ]


def _target_form(case: Case, history: list[ModelShow]) -> str:
    if FORM_MODE == "full":
        return "full"
    usable = [s for s in history if len(s.songs) >= PARAMS.min_show_songs]
    return classify_length(len([x for x in case.target.songs if not x["tape"]]), usable, PARAMS)


def _model_predictor(params: ModelParams | None = None, **flags):
    def predict(case: Case) -> list[str]:
        history = _model_history(case)
        result = predict_setlist(history, _target_form(case, history), params or PARAMS, **flags)
        return [song["name"] for song in result]

    return predict


# 단계를 하나씩 켜며 누적 비교 - A1 최근성만 / A2 +투어·형태·스무딩 / A3 +곡 수 추정 / A4 +순서
_OFF = dict(tour=False, form=False, smoothing=False, estimate_length=False, order=False)
PREDICTORS = {
    "A0": predict_a0,
    # 대조군: 최근성 없이 빈도만(반감기 무한) - A1의 이득 중 테이프 제외/곡명 정규화/빈 공연 제거 몫을 분리
    "A0n": _model_predictor(ModelParams(half_life=1e12), **_OFF),
    "A1": _model_predictor(**_OFF),
    "A2": _model_predictor(**{**_OFF, "tour": True, "form": True, "smoothing": True}),
    "A3": _model_predictor(**{**_OFF, "tour": True, "form": True, "smoothing": True, "estimate_length": True}),
    "A4": _model_predictor(),
}


# 예측 순서와 정답 순서가 같은 방향인 곡 쌍의 비율을 [-1, 1]로 (공통 곡 2개 미만이면 None)
def kendall_tau(pred_keys: list[str], truth_keys: list[str]) -> float | None:
    truth_pos = {k: i for i, k in enumerate(truth_keys)}
    common = [k for k in pred_keys if k in truth_pos]
    pairs = list(combinations(common, 2))
    if not pairs:
        return None
    concordant = sum(1 for a, b in pairs if truth_pos[a] < truth_pos[b])
    return (concordant - (len(pairs) - concordant)) / len(pairs)


def evaluate(pred: list[str], case: Case) -> dict:
    truth_keys: list[str] = []
    for song in case.target.songs:
        key = title_key(song["name"])
        if not song["tape"] and key and key not in truth_keys:
            truth_keys.append(key)
    pred_keys: list[str] = []
    for name in pred:
        key = title_key(name)
        if key and key not in pred_keys:
            pred_keys.append(key)

    hit = len(set(pred_keys) & set(truth_keys))
    precision = hit / len(pred_keys) if pred_keys else 0.0
    recall = hit / len(truth_keys) if truth_keys else 0.0
    f1 = 2 * precision * recall / (precision + recall) if hit else 0.0
    return {
        "precision": precision,
        "recall": recall,
        "f1": f1,
        "pred_n": len(pred_keys),
        "truth_n": len(truth_keys),
        "count_err": abs(len(pred_keys) - len(truth_keys)),
        "tau": kendall_tau(pred_keys, truth_keys),
    }


def _avg(values: list) -> float | None:
    values = [v for v in values if v is not None]
    return mean(values) if values else None


def _fmt(v: float | None) -> str:
    return "  -  " if v is None else f"{v:.3f}"


def run(names: list[str], n_targets: int, min_history: int) -> dict:
    artists = load_all_artists()
    cases_by_artist = {a.name: split_cases(a, n_targets, min_history) for a in artists}
    skipped = [name for name, cases in cases_by_artist.items() if not cases]
    print(f"아티스트 {len(artists)}명 중 이력 부족으로 제외 {len(skipped)}명: {', '.join(skipped) or '-'}")
    total_cases = sum(len(c) for c in cases_by_artist.values())
    print(f"정답 공연 {total_cases}개 (아티스트당 최신 {n_targets}개, 이력 곡있는 공연 {min_history}개 이상)\n")

    results: dict = {}
    for pname in names:
        predict = PREDICTORS[pname]
        per_artist = {}
        for artist_name, cases in cases_by_artist.items():
            if cases:
                per_artist[artist_name] = [evaluate(predict(c), c) for c in cases]
        results[pname] = per_artist

    metrics = ["precision", "recall", "f1", "count_err", "tau"]
    print(f"{'predictor':<10}" + "".join(f"{m:>11}" for m in metrics) + "   (아티스트 평균의 평균)")
    for pname, per_artist in results.items():
        row = {m: _avg([_avg([e[m] for e in evals]) for evals in per_artist.values()]) for m in metrics}
        print(f"{pname:<10}" + "".join(f"{_fmt(row[m]):>11}" for m in metrics))
    return results


# A0가 운영 _top_songs_for_artist와 같은 곡 목록을 내는지 - 검색만 캐시 이력으로 바꿔 끼워 비교
async def verify_a0(n_targets: int, min_history: int) -> None:
    from app.services import pre_setlist

    mismatches = checked = 0
    for artist in load_all_artists():
        for case in split_cases(artist, n_targets, min_history):
            raw = [
                {"sets": {"set": [{"encore": 1 if any(s["encore"] for s in show.songs) else None,
                                   "song": [{"name": s["name"]} for s in show.songs]}]}}
                for show in case.history[:LIVE_HISTORY_SHOWS]
            ]

            async def fake_search(db, artist_name, search, concert_id=None, _raw=raw):
                return _raw

            original = pre_setlist.search_with_artist_fallbacks
            pre_setlist.search_with_artist_fallbacks = fake_search
            try:
                live = [s["name"] for s in await pre_setlist._top_songs_for_artist(None, artist.name, 20)]
            finally:
                pre_setlist.search_with_artist_fallbacks = original
            checked += 1
            if live != predict_a0(case):
                mismatches += 1
                print(f"불일치: {artist.name} {case.target.date}")
    print(f"A0 검증: {checked}건 중 불일치 {mismatches}건")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--only", action="append", default=[], help="실행할 예측기 이름(여러 번 가능)")
    parser.add_argument("--targets", type=int, default=5, help="아티스트당 정답 공연 수")
    parser.add_argument("--min-history", type=int, default=5)
    parser.add_argument("--verify-a0", action="store_true")
    parser.add_argument("--form", choices=["full", "oracle"], default="full")
    args = parser.parse_args()
    global FORM_MODE
    FORM_MODE = args.form

    if args.verify_a0:
        asyncio.run(verify_a0(args.targets, args.min_history))
        return
    results = run(args.only or list(PREDICTORS), args.targets, args.min_history)
    _RESULT_DIR.mkdir(exist_ok=True)
    (_RESULT_DIR / "latest.json").write_text(json.dumps(results, ensure_ascii=False, indent=1), "utf-8")


if __name__ == "__main__":
    main()
