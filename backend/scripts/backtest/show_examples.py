"""현재 방식(A0)과 모델(A4)의 예측 목록을 정답과 나란히 뽑는 스크립트 (문서/발표용, 캐시만 읽음).

사용법 (backend/에서):
    python scripts/backtest/show_examples.py --artist "Red Velvet" --artist NELL
"""

import argparse
import sys
from pathlib import Path

_BACKEND_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_BACKEND_ROOT))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import run_backtest as rb  # noqa: E402
from data import load_all_artists, split_cases, title_key  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--artist", action="append", required=True)
    parser.add_argument("--index", type=int, default=0, help="최신 정답 공연 중 몇 번째(0=가장 최근)")
    args = parser.parse_args()

    artists = {a.name: a for a in load_all_artists()}
    for name in args.artist:
        cases = split_cases(artists[name])
        case = cases[args.index]
        truth = [s["name"] for s in case.target.songs if not s["tape"]]
        truth_keys = {title_key(t) for t in truth}
        a0, a4 = rb.predict_a0(case), rb.PREDICTORS["A4"](case)
        print(f"\n### {name} / 정답 공연 {case.target.date} / 실제 {len(truth)}곡")
        print("| 순번 | 현재 방식 | 모델 | 실제 셋리 |")
        print("|---|---|---|---|")
        for i in range(max(len(a0), len(a4), len(truth))):
            cell = lambda lst: "" if i >= len(lst) else lst[i] + (" (O)" if title_key(lst[i]) in truth_keys else "")
            print(f"| {i + 1} | {cell(a0)} | {cell(a4)} | {truth[i] if i < len(truth) else ''} |")
        hit = lambda lst: sum(title_key(x) in truth_keys for x in lst)
        print(f"맞음: 현재 {hit(a0)}/{len(a0)} / 모델 {hit(a4)}/{len(a4)}")


if __name__ == "__main__":
    main()
