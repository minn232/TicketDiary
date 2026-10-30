"""
저장해 둔 병합 전 배치 결과(<이름>.batches.json)로 병합(extract_poster._merge_results)만 다시 돌리고,
정답 파일이 있으면 채점한다. 모델(vLLM)을 부르지 않으므로 몇 초면 끝난다.

병합 로직(_merge_results와 그 아래 필터/보정 함수)을 고친 뒤 이걸로 확인한다:
  - 추출 당시 결과(<이름>.raw.json 또는 <이름>.json)와 비교해 결과가 달라진 이미지와 필드를 보여준다.
  - 정답(<golden-dir>/<이름>.golden.json)이 있으면 추출 당시 결과와 지금 결과를 둘 다 채점해 나란히 보여준다.
프롬프트·타일링·모델 호출을 고친 경우는 배치 결과 자체가 달라지므로 이걸로는 확인할 수 없다 - 추출을
다시 돌려야 한다.

<이름>.batches.json은 extract_poster.py --out-dir과 test_crawl_extract.py가 결과 옆에 같이 저장한다.

정답 파일은 결과와 같은 6키 형태다. 확인하지 않은 필드는 키째 지우면 채점에서 빠진다(예: 라인업만 확인했으면
lineup만 남긴다). 값이 null이거나 []이면 "없어야 정답"으로 보고, 뭔가 뽑으면 오답(FP)으로 센다.
--init-golden으로 지금 결과를 초안으로 깔고 이미지를 보며 고치면 된다.

채점 기준(이름은 _artist_key로 표기 차이를 무시하고 비교):
    lineup_name   아티스트 이름                 P/R/F1
    lineup        (아티스트, 공연일)             P/R/F1
    timetable     (아티스트, 공연일, 시각)        P/R/F1 - 무대는 보지 않는다
    ticketing     (예매 단계, 날짜)              P/R/F1
    prices        (좌석 등급, 가격)              P/R/F1
    delivery      ticket_delivery_date          일치 여부
    food          other_info.food_allowed        일치 여부

사용:
    # 한 run 전체를 지금 병합 코드로 다시 병합해, 추출 당시 결과와 달라진 것만 보기
    /opt/llm-venv/bin/python server/replay_merge.py crawl_test_results/run_20261021_060244

    # 정답과 채점(추출 당시 vs 지금). -v면 이미지별로 빠진/잘못 뽑힌 항목까지 출력
    /opt/llm-venv/bin/python server/replay_merge.py crawl_test_results/run_20261021_060244 --golden server/golden -v

    # 정답 초안 만들기(이미 있는 정답 파일은 덮어쓰지 않음)
    /opt/llm-venv/bin/python server/replay_merge.py poster_image/results/펜타포트*.batches.json --init-golden server/golden

    # 다시 병합한 결과를 파일로 저장
    /opt/llm-venv/bin/python server/replay_merge.py crawl_test_results/run_20261021_060244 --out-dir /tmp/replayed
"""

import argparse
import contextlib
import io
import json
import re
import sys
from pathlib import Path

from extract_poster import _artist_key, merge_batches

BATCHES_SUFFIX = ".batches.json"
GOLDEN_SUFFIX = ".golden.json"
# 추출 당시 결과 파일 이름 후보. test_crawl_extract.py는 <id>.raw.json, extract_poster.py는 <이름>.json.
ORIGINAL_SUFFIXES = (".raw.json", ".json")

SET_FIELDS = ("lineup_name", "lineup", "timetable", "ticketing", "prices")
SCALAR_FIELDS = ("delivery", "food")
# 채점 항목이 정답 파일의 어느 키에서 오는지. 정답에 이 키가 없으면 그 항목은 채점하지 않는다.
FIELD_SOURCE_KEY = {
    "lineup_name": "lineup",
    "lineup": "lineup",
    "timetable": "timetable",
    "ticketing": "ticketing_date",
    "prices": "ticket_prices",
    "delivery": "ticket_delivery_date",
    "food": "other_info",
}


def _norm(text: str) -> str:
    """좌석 등급/예매 단계 표기 차이(대소문자, 공백, 기호)를 무시하는 비교 키."""
    folded = text.casefold()
    return re.sub(r"[\W_]+", "", folded) or folded.strip()


def _keys(result: dict, field: str) -> set[tuple]:
    """결과 하나에서 채점 항목 field의 비교 키 집합을 만든다."""
    if field in ("lineup_name", "lineup"):
        entries = [e for e in (result.get("lineup") or []) if e.get("artist")]
        if field == "lineup_name":
            return {(_artist_key(e["artist"]),) for e in entries}
        return {(_artist_key(e["artist"]), e.get("performance_date")) for e in entries}
    if field == "timetable":
        return {
            (_artist_key(e["artist"]), e.get("performance_date"), e.get("time"))
            for e in (result.get("timetable") or [])
            if e.get("artist")
        }
    if field == "ticketing":
        return {(_norm(e["phase"]), e.get("date")) for e in (result.get("ticketing_date") or []) if e.get("phase")}
    if field == "prices":
        return {
            (_norm(e["seat_type"]), e.get("price")) for e in (result.get("ticket_prices") or []) if e.get("seat_type")
        }
    raise ValueError(field)


def _scalar(result: dict, field: str):
    if field == "delivery":
        return result.get("ticket_delivery_date")
    if field == "food":
        return (result.get("other_info") or {}).get("food_allowed")
    raise ValueError(field)


def score(result: dict, golden: dict) -> dict:
    """결과 하나를 정답 하나로 채점한다. 정답에 키가 없는 항목은 빠진다.
    반환: {항목: {"tp","fp","fn","missing","extra"}} (집합 항목) / {항목: {"correct", "got", "want"}} (단일 값)."""
    scores: dict[str, dict] = {}
    for field in SET_FIELDS:
        if FIELD_SOURCE_KEY[field] not in golden:
            continue
        got, want = _keys(result, field), _keys(golden, field)
        scores[field] = {
            "tp": len(got & want),
            "fp": len(got - want),
            "fn": len(want - got),
            "missing": sorted(want - got, key=str),
            "extra": sorted(got - want, key=str),
        }
    for field in SCALAR_FIELDS:
        if FIELD_SOURCE_KEY[field] not in golden:
            continue
        got, want = _scalar(result, field), _scalar(golden, field)
        scores[field] = {"correct": got == want, "got": got, "want": want}
    return scores


def _prf(tp: int, fp: int, fn: int) -> tuple[float, float, float]:
    p = tp / (tp + fp) if tp + fp else 1.0
    r = tp / (tp + fn) if tp + fn else 1.0
    f = 2 * p * r / (p + r) if p + r else 0.0
    return p, r, f


def _field_summary(field: str, s: dict) -> str:
    if "correct" in s:
        return "O" if s["correct"] else "X"
    return f"{_prf(s['tp'], s['fp'], s['fn'])[2]:.2f}"


def _diff_fields(before: dict, after: dict) -> list[str]:
    """추출 당시 결과와 다시 병합한 결과에서 달라진 필드를 한 줄씩 설명한다."""
    lines = []
    for key in after:
        old, new = before.get(key), after.get(key)
        if old == new:
            continue
        if isinstance(old, list) or isinstance(new, list):
            old_items = [json.dumps(e, ensure_ascii=False, sort_keys=True) for e in old or []]
            new_items = [json.dumps(e, ensure_ascii=False, sort_keys=True) for e in new or []]
            added = [e for e in new_items if e not in old_items]
            removed = [e for e in old_items if e not in new_items]
            lines.append(f"{key}: {len(old_items)}개 -> {len(new_items)}개 (+{len(added)} -{len(removed)})")
            lines += [f"    + {e}" for e in added] + [f"    - {e}" for e in removed]
            if not added and not removed:
                lines.append("    (항목은 같고 순서만 다름)")
        else:
            lines.append(f"{key}: {json.dumps(old, ensure_ascii=False)} -> {json.dumps(new, ensure_ascii=False)}")
    return lines


def _collect_batches(paths: list[str]) -> list[Path]:
    files: list[Path] = []
    for p in map(Path, paths):
        if p.is_dir():
            files.extend(sorted(p.glob(f"*{BATCHES_SUFFIX}")))
        elif p.name.endswith(BATCHES_SUFFIX):
            files.append(p)
        else:
            print(f"[건너뜀] {p}: 폴더나 *{BATCHES_SUFFIX} 파일이 아닙니다", file=sys.stderr)
    return files


def _name_of(batches_path: Path) -> str:
    return batches_path.name[: -len(BATCHES_SUFFIX)]


def _load_original(batches_path: Path) -> dict | None:
    for suffix in ORIGINAL_SUFFIXES:
        path = batches_path.with_name(_name_of(batches_path) + suffix)
        if path.exists():
            data = json.loads(path.read_text(encoding="utf-8"))
            return {k: v for k, v in data.items() if not k.startswith("_")}
    return None


def _print_totals(totals: dict[str, dict[str, dict]], labels: list[str]) -> None:
    """totals: {라벨("당시"/"지금"): {항목: 누적값}} - 이미지 전체를 합쳐(micro) 항목별로 출력한다."""
    print("\n== 전체 채점 (이미지 합산) ==")
    header = f"{'항목':<12}" + "".join(f"{label + ' P/R/F1':>26}" for label in labels)
    print(header)
    for field in SET_FIELDS:
        if not any(field in totals[label] for label in labels):
            continue
        row = f"{field:<12}"
        for label in labels:
            t = totals[label].get(field)
            if t is None:
                row += f"{'-':>26}"
                continue
            p, r, f = _prf(t["tp"], t["fp"], t["fn"])
            row += f"{f'{p:.3f}/{r:.3f}/{f:.3f}':>26}"
        print(row)
    for field in SCALAR_FIELDS:
        if not any(field in totals[label] for label in labels):
            continue
        row = f"{field:<12}"
        for label in labels:
            t = totals[label].get(field)
            row += f"{'-':>26}" if t is None else f"{f'{t[0]}/{t[1]} 일치':>26}"
        print(row)


def _accumulate(total: dict, scores: dict) -> None:
    for field, s in scores.items():
        if "correct" in s:
            c, n = total.get(field, (0, 0))
            total[field] = (c + int(s["correct"]), n + 1)
        else:
            t = total.setdefault(field, {"tp": 0, "fp": 0, "fn": 0})
            for k in ("tp", "fp", "fn"):
                t[k] += s[k]


def main() -> None:
    parser = argparse.ArgumentParser(description="저장된 배치 결과로 병합만 다시 돌리고 채점한다(모델 호출 없음)")
    parser.add_argument("paths", nargs="+", help=f"*{BATCHES_SUFFIX} 파일 또는 그 파일들이 있는 폴더")
    parser.add_argument("--golden", default=None, help=f"정답 폴더(<이름>{GOLDEN_SUFFIX})")
    parser.add_argument("--init-golden", default=None, metavar="DIR", help="지금 병합 결과를 정답 초안으로 저장(덮어쓰지 않음)")
    parser.add_argument("--out-dir", default=None, help="다시 병합한 결과를 <이름>.json으로 저장")
    parser.add_argument("-v", "--verbose", action="store_true", help="빠진/잘못 뽑힌 항목과 병합 중 경고까지 출력")
    args = parser.parse_args()

    files = _collect_batches(args.paths)
    if not files:
        print(f"*{BATCHES_SUFFIX} 파일이 없습니다.", file=sys.stderr)
        sys.exit(1)

    golden_dir = Path(args.golden) if args.golden else None
    out_dir = Path(args.out_dir) if args.out_dir else None
    init_dir = Path(args.init_golden) if args.init_golden else None
    for d in (out_dir, init_dir):
        if d:
            d.mkdir(parents=True, exist_ok=True)

    totals: dict[str, dict] = {"당시": {}, "지금": {}}
    n_changed = n_scored = n_scored_original = 0
    for path in files:
        name = _name_of(path)
        batches = json.loads(path.read_text(encoding="utf-8"))
        # _warn_if_undercounted 등 병합 중 경고는 추출 때 이미 봤으므로 -v일 때만 보여준다.
        stderr = io.StringIO()
        with contextlib.redirect_stderr(sys.stderr if args.verbose else stderr):
            merged = merge_batches(batches)
        original = _load_original(path)

        version = batches.get("_pipeline_version", "?")
        print(f"\n=== {name} (배치 {len(batches['results'])}개, 추출 버전 {version}) ===")
        if original is None:
            print("추출 당시 결과 파일 없음 - 비교 생략")
        else:
            diff = _diff_fields(original, merged)
            if diff:
                n_changed += 1
                print("추출 당시 결과와 달라짐:")
                print("\n".join("  " + line for line in diff))
            else:
                print("추출 당시 결과와 같음")

        golden_path = golden_dir / f"{name}{GOLDEN_SUFFIX}" if golden_dir else None
        if golden_path and golden_path.exists():
            golden = json.loads(golden_path.read_text(encoding="utf-8"))
            n_scored += 1
            now = score(merged, golden)
            _accumulate(totals["지금"], now)
            parts = [f"{f} {_field_summary(f, s)}" for f, s in now.items()]
            if original is not None:
                n_scored_original += 1
                _accumulate(totals["당시"], score(original, golden))
            print("채점(F1 / 일치): " + "  ".join(parts))
            if args.verbose:
                for field, s in now.items():
                    if "correct" in s:
                        if not s["correct"]:
                            print(f"  {field}: 정답 {s['want']!r}, 결과 {s['got']!r}")
                        continue
                    for item in s["missing"]:
                        print(f"  {field} 빠짐: {item}")
                    for item in s["extra"]:
                        print(f"  {field} 잘못 뽑힘: {item}")

        if out_dir:
            (out_dir / f"{name}.json").write_text(json.dumps(merged, ensure_ascii=False, indent=2), encoding="utf-8")
        if init_dir:
            target = init_dir / f"{name}{GOLDEN_SUFFIX}"
            if target.exists():
                print(f"정답 파일이 이미 있어 초안을 만들지 않음: {target}")
            else:
                target.write_text(json.dumps(merged, ensure_ascii=False, indent=2), encoding="utf-8")
                print(f"정답 초안 저장: {target} - 이미지와 대조해 고칠 것(확인 안 한 필드는 키를 지울 것)")

    print(f"\n총 {len(files)}건 다시 병합, 추출 당시와 달라진 건 {n_changed}건", end="")
    print(f", 정답 있는 건 {n_scored}건" if golden_dir else "")
    if n_scored:
        # 추출 당시 결과가 없는 건이 섞이면 두 열의 채점 대상이 달라 비교가 안 되므로 "지금"만 보여준다.
        labels = ["당시", "지금"] if n_scored_original == n_scored else ["지금"]
        _print_totals(totals, labels)


if __name__ == "__main__":
    main()
