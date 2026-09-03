"""extract_artist_info를 백엔드/HTTP API 없이 순수 함수 호출로 여러 건 한 번에 돌려보는
테스트 스크립트. CSV(kopis_id,concert_name,poster_url)를 읽어서 pod 로컬 vLLM에 그대로
태우고 결과를 <kopis_id>.json으로 저장한다. concert_name/poster_url은 DB에서 미리
export해서 CSV로 만들어 pod에 올려두면 됨(백엔드 API 호출 불필요).

extract_artist_info는 동기 함수라 asyncio 대신 ThreadPoolExecutor로 동시 실행한다(vLLM은
continuous batching이라 여러 요청을 동시에 받아도 처리 가능 - main.py의 BATCH_CONCURRENCY와
같은 이유). --concurrency로 동시 요청 수 조절, 너무 높이면 vLLM이 OOM 날 수 있으니 낮게
시작해서 올릴 것.

1300건 규모로 돌려보니 예외(포스터 다운로드 실패/vLLM 순간 과부하 등)가 나면 그 건은
stderr에 한 줄 찍히고 그대로 유실됐다 - 터미널 스크롤이 끝나면 어떤 건이 왜 실패했는지
다시 알 방법이 없고, 재시도도 안 걸렸다. 그래서 세 가지를 추가했다:
  1. 건별 자동 재시도(--retries, 기본 2회, 지수백오프) - 대부분 일시적 오류라 재시도로 해결됨
  2. 재시도까지 다 실패한 건만 <out-dir>/failed.csv 에 kopis_id/concert_name/poster_url/에러
     사유로 남긴다 - 로그가 사라져도 이 CSV만 보면 뭐가 왜 실패했는지 바로 알 수 있고,
     그대로 --csv 인자로 다시 넣어 재시도용 배치를 돌릴 수 있다.
  3. --resume: out-dir에 이미 결과 json이 있는 kopis_id는 건너뛴다 - 같은 CSV를 그대로 다시
     돌려도 이미 끝난 건 재작업하지 않고 실패/누락분만 자동으로 메꿔진다.

사용법 (pod에서):
    python test_batch_extract.py test_concerts.csv                         # 전체, 동시 5건
    python test_batch_extract.py test_concerts.csv --concurrency 10        # 동시 10건
    python test_batch_extract.py test_concerts.csv --filter "9와 숫자들"    # 공연명에 포함된 것만
    python test_batch_extract.py test_concerts.csv --kopis-id PF282325     # 정확히 하나만 (kopis_id로)
    python test_batch_extract.py test_concerts.csv --base-url http://localhost:8000/v1 --out-dir results
    python test_batch_extract.py test_concerts.csv --resume                # 이미 끝난 건 건너뛰고 나머지만
    python test_batch_extract.py batch_results/failed.csv --out-dir batch_results  # 실패건만 재시도
"""

import argparse
import csv
import json
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from extract_artist import extract_artist_info


def _process_row(
    row: dict, out_dir: Path, base_url: str, api_key: str, retries: int
) -> tuple[str, list[str] | None, Exception | None]:
    name = row["concert_name"]
    poster_url = row["poster_url"]
    kopis_id = row.get("kopis_id") or name
    venue = row.get("venue") or None  # CSV에 venue 컬럼이 없으면 그냥 None(기존과 동일하게 동작)

    exc: Exception | None = None
    for attempt in range(retries + 1):
        try:
            result = extract_artist_info(poster_url, name, base_url, api_key, venue)
            break
        except Exception as e:  # noqa: BLE001
            exc = e
            if attempt < retries:
                time.sleep(2**attempt)  # 1s, 2s, 4s, ...
    else:
        return name, None, exc

    artists = [e.get("artist") for e in result.get("lineup", []) if e.get("artist")]
    (out_dir / f"{kopis_id}.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return name, artists, None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "csv_path", help="kopis_id,concert_name,poster_url 컬럼을 가진 CSV (venue 컬럼은 선택, 있으면 프롬프트 근거로 씀)"
    )
    parser.add_argument("--filter", default=None, help="공연명에 이 문자열이 포함된 행만 실행 (대소문자 무시)")
    parser.add_argument("--kopis-id", default=None, help="이 kopis_id 하나만 정확히 실행")
    parser.add_argument("--concurrency", type=int, default=5, help="동시 요청 수 (기본 5, vLLM 메모리 봐가며 조절)")
    parser.add_argument("--base-url", default="http://localhost:8000/v1")
    parser.add_argument("--api-key", default="EMPTY")
    parser.add_argument("--out-dir", default="batch_results")
    parser.add_argument("--retries", type=int, default=2, help="건별 실패 시 재시도 횟수 (기본 2, 지수백오프)")
    parser.add_argument("--resume", action="store_true", help="out-dir에 이미 <kopis_id>.json이 있는 건은 건너뛴다")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    with open(args.csv_path, encoding="utf-8") as f:
        rows = list(csv.DictReader(f))

    if args.kopis_id:
        rows = [r for r in rows if r.get("kopis_id") == args.kopis_id]
    if args.filter:
        needle = args.filter.lower()
        rows = [r for r in rows if needle in r["concert_name"].lower()]
    if (args.kopis_id or args.filter) and not rows:
        print("조건에 맞는 행이 없습니다 (--filter/--kopis-id 확인)", file=sys.stderr)
        sys.exit(1)

    if args.resume:
        before = len(rows)
        rows = [r for r in rows if not (out_dir / f"{r.get('kopis_id') or r['concert_name']}.json").exists()]
        print(f"--resume: {before}건 중 {before - len(rows)}건은 이미 완료돼 건너뜀, {len(rows)}건만 실행")

    print(f"{len(rows)}건 테스트 시작 (동시 {args.concurrency}건, base_url={args.base_url})")

    done = 0
    failed: list[tuple[dict, Exception]] = []
    lock = threading.Lock()
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        futures = {
            pool.submit(_process_row, row, out_dir, args.base_url, args.api_key, args.retries): row
            for row in rows
        }
        for future in as_completed(futures):
            row = futures[future]
            name, artists, exc = future.result()
            with lock:
                done += 1
                progress = f"[{done}/{len(rows)}]"
            if exc is not None:
                failed.append((row, exc))
                print(f"{progress} {name} -> 실패({args.retries+1}회 시도 모두 실패): {exc}", file=sys.stderr)
            else:
                print(f"{progress} {name} -> {artists}")

    print(f"완료. 결과는 {out_dir}/ 에 저장됨")

    if failed:
        failed_csv = out_dir / "failed.csv"
        with open(failed_csv, "w", encoding="utf-8", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["kopis_id", "concert_name", "poster_url", "error"])
            for row, exc in failed:
                writer.writerow(
                    [row.get("kopis_id", ""), row["concert_name"], row["poster_url"], str(exc)]
                )
        print(
            f"{len(failed)}건은 재시도까지 전부 실패 -> {failed_csv} 에 사유와 함께 저장됨 "
            f"(이 CSV를 그대로 --csv 인자로 다시 넣어 재시도 가능)",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
