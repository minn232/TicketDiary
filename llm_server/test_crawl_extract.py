"""analyze_crawl_screenshot(=extract_poster_info + normalize_crawl_result)을 백엔드/HTTP API
없이 순수 함수 호출로 여러 건 돌려보고, 결과를 규칙 기반으로 훑어 "이미지를 직접 열어봐야
할 건"을 걸러주는 테스트 스크립트. backend/scripts/ongoing/export_llm_crawl_samples.py가 뽑은
JSON(crawl_screenshot_url이 있는 진행예정 공연 전부)을 읽어서, 그중 원하는 만큼 골라 돌린다.

llm_server의 /crawl-analyze HTTP 경로는 쓰지 않는다 - 그 경로를 타면 콜백이 실서버로 가서
Concert.crawl_result_received_at이 찍히고, 9/28 실연동 배치 대상에서 빠지거나 artist_name이
덮어써지는 부작용이 있다. 대신 extract_poster_info + normalize_crawl_result를 직접 호출해서
실제 경로(inference.analyze_crawl_screenshot)와 동일한 결과를 얻되 DB에는 아무것도 안 쓴다.
동시 실행에 asyncio 대신 ThreadPoolExecutor를 쓰는 이유, 재시도/--resume/failed.csv 설계는
test_batch_extract.py(아티스트 추출 쪽)와 동일한 근거.

건별 결과는 <out-dir>/<run-name>/ 아래 <concert_id>.raw.json(모델 원본 응답,
extract_poster_info 반환값 그대로), <concert_id>.callback.json(normalize_crawl_result를 거친
값 - 백엔드가 실제로 받을 콜백 바디)로 저장되고, summary.csv에 건별 한 줄 요약 + 경고 코드가
모인다.

경고(C1~C7)는 "여기 요청 1/2/3을 반영했는지"를 보는 게 아니라, 프롬프트나 병합 로직을 어떻게
바꾸든 항상 적용되는 일반 점검이다. 코드 기준은 파일 하단 _evaluate_warnings 근처 주석 참고.
경고는 채점이 아니라 규칙 기반 힌트라 오탐이 있을 수 있다 - 경고 없는 건도 몇 개는 이미지와
직접 대조해볼 것.

사용법 (pod에서):
    /workspace/venv/bin/python server/test_crawl_extract.py server/llm_crawl_samples.json                              # 전체, 동시 5건
    /workspace/venv/bin/python server/test_crawl_extract.py server/llm_crawl_samples.json --limit 20                   # 앞 20건만
    /workspace/venv/bin/python server/test_crawl_extract.py server/llm_crawl_samples.json --concert-id <uuid>          # 정확히 하나만
    /workspace/venv/bin/python server/test_crawl_extract.py server/llm_crawl_samples.json --event-type SOLO            # 단독 공연만
    /workspace/venv/bin/python server/test_crawl_extract.py server/llm_crawl_samples.json --filter "펜타포트"           # 공연명에 포함된 것만
    /workspace/venv/bin/python server/test_crawl_extract.py server/llm_crawl_samples.json --no-ranges                  # 구간 무시하고 돌려서 비교
    /workspace/venv/bin/python server/test_crawl_extract.py server/llm_crawl_samples.json --run-name before            # 결과 폴더 이름 지정
    /workspace/venv/bin/python server/test_crawl_extract.py server/llm_crawl_samples.json --resume                     # 이미 끝난 건 건너뛰고 나머지만
    /workspace/venv/bin/python server/test_crawl_extract.py server/llm_crawl_samples.json --out-dir crawl_test_results/failed.csv  # 실패건만 재시도
    /workspace/venv/bin/python server/test_crawl_extract.py --compare before after                    # 두 run 결과 비교(추출 없이)

    
"""

import argparse
import csv
import json
import re
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date, datetime, timedelta
from pathlib import Path

from extract_poster import extract_poster_info
from normalize import normalize_crawl_result

# 콜백에 값이 있을 때만 채워지는 필드들(normalize_crawl_result 참고) - C1 판정에 씀. lineup은
# artist_name/timetable과 내용이 겹치는 보조 필드라 "필드 수"에서는 제외한다.
_CONTENT_FIELDS = (
    "timetable",
    "prices",
    "ticketing_date",
    "ticketing_phases",
    "delivery_date",
    "artist_name",
    "food_allowed",
)

_TIME_RE = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")

# 아티스트명에 이런 단어가 섞여 있으면 실제 아티스트가 아니라 안내 문구/부대행사/좌석 등급일
# 가능성이 높다(요청 1~3과 무관하게, 프롬프트·병합 로직이 어떻게 바뀌든 항상 확인해볼 값).
_SUSPICIOUS_NAME_RE = re.compile(
    r"티켓|예매|부스|입장|게이트|오픈|안내|좌석|공연장|매표|주차|물품보관|셔틀|인터미션|"
    r"사인회|MD|굿즈|리허설|사운드체크|팔찌|ticket|gate|box\s*office|entrance",
    re.IGNORECASE,
)


def _load_samples(json_path: str) -> list[dict]:
    with open(json_path, encoding="utf-8") as f:
        return json.load(f)


def _parse_date(value: str | None) -> date | None:
    if not value:
        return None
    try:
        return datetime.strptime(value[:10], "%Y-%m-%d").date()
    except ValueError:
        return None


def _evaluate_warnings(callback: dict, sample: dict) -> list[tuple[str, str]]:
    """(코드, 상세문구) 목록. 경고가 없으면 빈 리스트."""
    warnings: list[tuple[str, str]] = []
    start = _parse_date(sample.get("start_date"))
    end = _parse_date(sample.get("end_date"))
    had_ranges = bool(sample.get("timetable_ranges"))

    # C1: 거의 빈 결과 - 콜백 필드가 1개 이하
    filled = sum(1 for k in _CONTENT_FIELDS if callback.get(k) not in (None, [], ""))
    if filled <= 1:
        warnings.append(("C1", f"콜백 필드 {filled}개만 채워짐"))

    # C2: 아티스트 없음
    artist_names = callback.get("artist_name") or []
    if not artist_names:
        warnings.append(("C2", "artist_name 비어있음"))

    # C3: 아티스트명이 이상함
    concert_name = (sample.get("concert_name") or "").strip()
    for name in artist_names:
        if not name:
            continue
        reason = None
        if name.strip() == concert_name:
            reason = "공연명과 동일"
        elif len(name) > 30:
            reason = f"{len(name)}자로 너무 김"
        elif _SUSPICIOUS_NAME_RE.search(name):
            reason = "안내성 단어 포함"
        if reason:
            warnings.append(("C3", f'"{name}" ({reason})'))

    # C4: 시간표가 이상함
    timetable = callback.get("timetable") or []
    if had_ranges and not timetable:
        warnings.append(("C4", "구간이 주어졌는데 timetable 비어있음"))
    for e in timetable:
        t = e.get("time")
        if t and not _TIME_RE.match(t):
            warnings.append(("C4", f'time 형식 이상: "{t}"'))
        if e.get("event") == "라인업 미공개":
            warnings.append(("C4", "이름 없는 시간표 항목(라인업 미공개)"))
        d = _parse_date(e.get("date"))
        if d and start and end and not (start <= d <= end):
            warnings.append(("C4", f"timetable date {e.get('date')}가 공연 기간({start}~{end}) 밖"))

    # C5: 가격이 이상함
    prices = callback.get("prices") or []
    if not prices:
        warnings.append(("C5", "prices 비어있음"))
    seen_seat_types: dict[str, int] = {}
    for p in prices:
        price = p.get("price")
        if price is not None and (price < 1000 or price > 1_000_000):
            warnings.append(("C5", f"{p.get('seat_type')} 가격 {price}원이 범위 밖"))
        seat_type = p.get("seat_type")
        if seat_type:
            if seat_type in seen_seat_types and seen_seat_types[seat_type] != price:
                warnings.append(("C5", f'"{seat_type}"이 서로 다른 가격으로 중복'))
            seen_seat_types[seat_type] = price

    # C6: 날짜가 이상함
    ticketing_date = _parse_date(callback.get("ticketing_date"))
    if ticketing_date and start:
        if ticketing_date > start:
            warnings.append(("C6", f"ticketing_date {ticketing_date}가 공연 시작일({start})보다 뒤"))
        elif ticketing_date < start - timedelta(days=365):
            warnings.append(("C6", f"ticketing_date {ticketing_date}가 공연 시작일보다 1년 넘게 앞"))
    delivery_date = _parse_date(callback.get("delivery_date"))
    if delivery_date:
        if ticketing_date and delivery_date < ticketing_date:
            warnings.append(("C6", f"delivery_date {delivery_date}가 ticketing_date보다 앞"))
        if end and delivery_date > end:
            warnings.append(("C6", f"delivery_date {delivery_date}가 공연 종료일({end})보다 뒤"))
    phases = callback.get("ticketing_phases") or []
    phase_dates = [_parse_date(p.get("date")) for p in phases if p.get("date")]
    if phase_dates != sorted(phase_dates):
        warnings.append(("C6", "ticketing_phases 날짜 순서가 뒤바뀜"))

    return warnings


def _process_row(
    sample: dict,
    out_dir: Path,
    base_url: str,
    api_key: str,
    retries: int,
    timeout: float,
    use_ranges: bool,
    slow_threshold: float,
) -> dict:
    concert_id = sample["concert_id"]
    screenshot_url = sample["screenshot_url"]
    ranges = sample.get("timetable_ranges") if use_ranges else None
    timetable_ranges = [tuple(r) for r in ranges] if ranges else None

    exc: Exception | None = None
    raw: dict | None = None
    elapsed = 0.0
    start = time.monotonic()
    for attempt in range(retries + 1):
        try:
            raw = extract_poster_info(
                screenshot_url, base_url, api_key, timeout=timeout, timetable_ranges=timetable_ranges
            )
            break
        except Exception as e:  # noqa: BLE001
            exc = e
            if attempt < retries:
                time.sleep(2**attempt)  # 1s, 2s, 4s, ...
    elapsed = time.monotonic() - start

    if raw is None:
        return {"concert_id": concert_id, "sample": sample, "error": exc, "elapsed": elapsed}

    callback = normalize_crawl_result(raw, sample.get("concert_name"))
    warnings = _evaluate_warnings(callback, sample)
    if elapsed > slow_threshold:
        warnings.append(("C7", f"{elapsed:.1f}초 소요(기준 {slow_threshold:.0f}초)"))

    (out_dir / f"{concert_id}.raw.json").write_text(
        json.dumps(raw, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (out_dir / f"{concert_id}.callback.json").write_text(
        json.dumps(callback, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    return {
        "concert_id": concert_id,
        "sample": sample,
        "callback": callback,
        "warnings": warnings,
        "elapsed": elapsed,
        "error": None,
    }


def _summary_line(row: dict) -> str:
    cb = row["callback"]
    name = row["sample"].get("concert_name") or row["concert_id"]
    parts = [
        f"시간표 {len(cb.get('timetable') or [])}",
        f"가격 {len(cb.get('prices') or [])}",
        f"예매 {cb.get('ticketing_date') or '-'}",
        f"아티스트 {cb.get('artist_name') or []}",
    ]
    return f"{name}  ({row['elapsed']:.1f}초)  " + " | ".join(parts)


def _run_extraction(args: argparse.Namespace) -> None:
    samples = _load_samples(args.json_path)

    if args.concert_id:
        wanted = set(args.concert_id)
        samples = [s for s in samples if s["concert_id"] in wanted]
    if args.event_type:
        samples = [s for s in samples if s.get("event_type") == args.event_type]
    if args.filter:
        needle = args.filter.lower()
        samples = [s for s in samples if needle in (s.get("concert_name") or "").lower()]
    if (args.concert_id or args.event_type or args.filter) and not samples:
        print("조건에 맞는 표본이 없습니다 (--concert-id/--event-type/--filter 확인)", file=sys.stderr)
        sys.exit(1)
    if args.limit:
        samples = samples[: args.limit]

    run_name = args.run_name or time.strftime("run_%Y%m%d_%H%M%S")
    out_dir = Path(args.out_dir) / run_name
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.resume:
        before = len(samples)
        samples = [s for s in samples if not (out_dir / f"{s['concert_id']}.callback.json").exists()]
        print(f"--resume: {before}건 중 {before - len(samples)}건은 이미 완료돼 건너뜀, {len(samples)}건만 실행")

    print(
        f"{len(samples)}건 테스트 시작 (동시 {args.concurrency}건, base_url={args.base_url}, "
        f"run={run_name}, ranges={'off' if args.no_ranges else 'on'})"
    )

    done = 0
    results: list[dict] = []
    lock = threading.Lock()
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        futures = {
            pool.submit(
                _process_row,
                sample,
                out_dir,
                args.base_url,
                args.api_key,
                args.retries,
                args.timeout,
                not args.no_ranges,
                args.slow_threshold,
            ): sample
            for sample in samples
        }
        for future in as_completed(futures):
            row = future.result()
            results.append(row)
            with lock:
                done += 1
                progress = f"[{done}/{len(samples)}]"
            if row["error"] is not None:
                print(
                    f"{progress} {row['sample'].get('concert_name')} -> 실패"
                    f"({args.retries + 1}회 시도 모두 실패): {row['error']}",
                    file=sys.stderr,
                )
            else:
                print(f"{progress} {_summary_line(row)}")
                for code, detail in row["warnings"]:
                    print(f"        ⚠ {code} {detail}")

    print(f"\n완료. 결과는 {out_dir}/ 에 저장됨")
    _write_summary_csv(out_dir, results)
    _write_failed_csv(out_dir, results)
    _print_totals(results)


def _write_summary_csv(out_dir: Path, results: list[dict]) -> None:
    ok_rows = [r for r in results if r["error"] is None]
    with open(out_dir / "summary.csv", "w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(
            [
                "concert_id",
                "concert_name",
                "event_type",
                "구간수",
                "걸린초",
                "timetable수",
                "prices수",
                "ticketing_date",
                "artist수",
                "food_allowed",
                "경고",
                "경고_상세",
            ]
        )
        for r in ok_rows:
            sample = r["sample"]
            cb = r["callback"]
            codes = ";".join(sorted({c for c, _ in r["warnings"]}))
            details = " / ".join(f"{c}: {d}" for c, d in r["warnings"])
            writer.writerow(
                [
                    r["concert_id"],
                    sample.get("concert_name"),
                    sample.get("event_type"),
                    len(sample.get("timetable_ranges") or []),
                    f"{r['elapsed']:.1f}",
                    len(cb.get("timetable") or []),
                    len(cb.get("prices") or []),
                    cb.get("ticketing_date") or "",
                    len(cb.get("artist_name") or []),
                    cb.get("food_allowed") or "",
                    codes,
                    details,
                ]
            )
    print(f"요약: {out_dir}/summary.csv")


def _write_failed_csv(out_dir: Path, results: list[dict]) -> None:
    failed = [r for r in results if r["error"] is not None]
    if not failed:
        return
    with open(out_dir / "failed.csv", "w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["concert_id", "concert_name", "screenshot_url", "error"])
        for r in failed:
            s = r["sample"]
            writer.writerow([s["concert_id"], s.get("concert_name"), s.get("screenshot_url"), str(r["error"])])
    print(
        f"{len(failed)}건은 재시도까지 전부 실패 -> {out_dir}/failed.csv 에 사유와 함께 저장됨",
        file=sys.stderr,
    )


def _print_totals(results: list[dict]) -> None:
    ok = [r for r in results if r["error"] is None]
    failed_count = len(results) - len(ok)
    with_warnings = sum(1 for r in ok if r["warnings"])
    print(f"\n{len(ok)}건 완료 (실패 {failed_count}) | 경고 있는 건 {with_warnings}")

    counts: dict[str, int] = {}
    for r in ok:
        for code, _ in r["warnings"]:
            counts[code] = counts.get(code, 0) + 1
    order = ["C1", "C2", "C3", "C4", "C5", "C6", "C7"]
    print(" | ".join(f"{c} {counts.get(c, 0)}" for c in order))
    print(
        "\n경고는 채점이 아니라 확인 힌트입니다. 경고가 없어도 시각·가격 값 자체가 틀렸을 수 "
        "있으니, 경고 없는 건도 몇 개는 이미지와 직접 대조해 주세요."
    )


# ── --compare: 두 run의 결과를 공연별로 비교 (추출은 다시 안 함) ──────────────────────
def _load_run(out_dir: Path, run_name: str) -> dict[str, dict]:
    run_dir = out_dir / run_name
    callbacks: dict[str, dict] = {}
    for path in run_dir.glob("*.callback.json"):
        concert_id = path.name.removesuffix(".callback.json")
        callbacks[concert_id] = json.loads(path.read_text(encoding="utf-8"))
    return callbacks


def _run_compare(args: argparse.Namespace) -> None:
    out_dir = Path(args.out_dir)
    before = _load_run(out_dir, args.compare[0])
    after = _load_run(out_dir, args.compare[1])

    common = sorted(set(before) & set(after))
    only_before = set(before) - set(after)
    only_after = set(after) - set(before)
    print(f"{args.compare[0]}: {len(before)}건, {args.compare[1]}: {len(after)}건, 공통 {len(common)}건")
    if only_before:
        print(f"{args.compare[0]}에만 있음: {len(only_before)}건")
    if only_after:
        print(f"{args.compare[1]}에만 있음: {len(only_after)}건")

    changed = 0
    for concert_id in common:
        b, a = before[concert_id], after[concert_id]
        if b == a:
            continue
        changed += 1
        keys = sorted(set(b) | set(a))
        print(f"\n[{concert_id}] 변경됨")
        for k in keys:
            if b.get(k) != a.get(k):
                print(f"  {k}: {b.get(k)!r} -> {a.get(k)!r}")
    print(f"\n총 {changed}/{len(common)}건 변경됨")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("json_path", nargs="?", help="export_llm_crawl_samples.py가 만든 JSON")
    parser.add_argument("--concert-id", action="append", default=None, help="이 concert_id만 (여러 번 지정 가능)")
    parser.add_argument("--event-type", default=None, choices=["SOLO", "FESTIVAL", "UNKNOWN"], help="이 event_type만")
    parser.add_argument("--filter", default=None, help="공연명에 이 문자열이 포함된 것만 (대소문자 무시)")
    parser.add_argument("--limit", type=int, default=None, help="필터링 후 앞에서 N건만")
    parser.add_argument("--no-ranges", action="store_true", help="timetable_ranges를 무시하고 돌려서 구간 효과 비교")
    # config.py는 import 안 함(LLM_EXTRACT_API_KEY 등 필수 환경변수가 없으면 .env 없이 실행이
    # 막힘 - test_batch_extract.py와 같은 이유). 기본값은 config.py의 값과 동일하게 맞춤
    parser.add_argument("--concurrency", type=int, default=5, help="동시 요청 수 (기본 5, config.py의 CRAWL_BATCH_CONCURRENCY와 동일)")
    parser.add_argument("--base-url", default="http://localhost:8000/v1")
    parser.add_argument("--api-key", default="EMPTY")
    parser.add_argument("--timeout", type=float, default=600.0, help="건별 모델 요청 타임아웃(초)")
    parser.add_argument("--slow-threshold", type=float, default=180.0, help="이 초를 넘으면 C7 경고(기본 180)")
    parser.add_argument("--out-dir", default="crawl_test_results")
    parser.add_argument("--run-name", default=None, help="결과 폴더 이름 (기본: run_현재시각)")
    parser.add_argument("--retries", type=int, default=2, help="건별 실패 시 재시도 횟수 (기본 2, 지수백오프)")
    parser.add_argument("--resume", action="store_true", help="out-dir/run-name에 이미 결과가 있는 건은 건너뜀")
    parser.add_argument(
        "--compare", nargs=2, metavar=("BEFORE_RUN", "AFTER_RUN"), default=None, help="추출 없이 두 run 결과만 비교"
    )
    args = parser.parse_args()

    if args.compare:
        _run_compare(args)
        return

    if not args.json_path:
        parser.error("json_path가 필요합니다 (--compare만 쓸 게 아니라면)")

    _run_extraction(args)


if __name__ == "__main__":
    main()
