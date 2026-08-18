"""extract_artist_info를 백엔드/HTTP API 없이 순수 함수 호출로 여러 건 한 번에 돌려보는
테스트 스크립트. CSV(kopis_id,concert_name,poster_url)를 읽어서 pod 로컬 vLLM에 그대로
태우고 결과를 <kopis_id>.json으로 저장한다. concert_name/poster_url은 DB에서 미리
export해서 CSV로 만들어 pod에 올려두면 됨(백엔드 API 호출 불필요).

사용법 (pod에서):
    python test_batch_extract.py test_concerts.csv                         # 전체 (156건)
    python test_batch_extract.py test_concerts.csv --filter "9와 숫자들"    # 공연명에 포함된 것만
    python test_batch_extract.py test_concerts.csv --kopis-id PF282325     # 정확히 하나만 (kopis_id로)
    python test_batch_extract.py test_concerts.csv --base-url http://localhost:8000/v1 --out-dir results
"""

import argparse
import csv
import json
import sys
from pathlib import Path

from extract_artist import extract_artist_info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv_path", help="kopis_id,concert_name,poster_url 컬럼을 가진 CSV")
    parser.add_argument("--filter", default=None, help="공연명에 이 문자열이 포함된 행만 실행 (대소문자 무시)")
    parser.add_argument("--kopis-id", default=None, help="이 kopis_id 하나만 정확히 실행")
    parser.add_argument("--base-url", default="http://localhost:8000/v1")
    parser.add_argument("--api-key", default="EMPTY")
    parser.add_argument("--out-dir", default="batch_results")
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

    print(f"{len(rows)}건 테스트 시작 (base_url={args.base_url})")
    for i, row in enumerate(rows, 1):
        name = row["concert_name"]
        poster_url = row["poster_url"]
        kopis_id = row.get("kopis_id") or str(i)
        try:
            result = extract_artist_info(poster_url, name, args.base_url, args.api_key)
        except Exception as exc:  # noqa: BLE001
            print(f"[{i}/{len(rows)}] {name} -> 실패: {exc}", file=sys.stderr)
            continue

        artists = [e.get("artist") for e in result.get("lineup", []) if e.get("artist")]
        print(f"[{i}/{len(rows)}] {name} -> {artists}")
        (out_dir / f"{kopis_id}.json").write_text(
            json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
        )

    print(f"완료. 결과는 {out_dir}/ 에 저장됨")


if __name__ == "__main__":
    main()
