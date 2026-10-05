"""배치 결과 1차 텍스트 스크리닝 (전수).

docs/artist_extraction_batch_review_2026-08-22.md 에 정리된 4가지 자동 체크를
test_concerts.csv 156건 전부에 대해 돌려서 의심 케이스를 추출한다.

체크 항목:
  1. 공연장/시설명 키워드가 아티스트 자리에 있는지
  2. 문자열 "null"/"none"/"n/a"이 아티스트로 리턴됐는지
  3. 동일 (artist, performance_date) 쌍이 결과 내에서 중복되는지
  4. 제목에 콜라보/페스티벌 힌트가 있는데 결과 아티스트가 1명뿐인지
  5. 한글 이름에 한자(CJK)가 섞여 들어갔는지 (2026-08-27 추가 - v3 few-shot 오염 조사 중
     "내귀에도청장치"→"内귀에도청장치"처럼 멀쩡한 한글 음절이 낯선 한자로 치환되는 버그를
     실제로 5건 발견해서 상시 자동검사 항목으로 편입함, docs 참고)

사용법 (backend/ 에서 실행 - --csv/--results-dir 생략하면 llm_server/ 기준 기본값 사용):
    python scripts/screen_batch_results.py
    python scripts/screen_batch_results.py --csv ../llm_server/test_concerts.csv --results-dir ../llm_server/batch_results
"""

import argparse
import csv
import json
import re
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
LLM_SERVER_DIR = _REPO_ROOT / "llm_server"
DEFAULT_OUT_DIR = _REPO_ROOT / "docs" / "qa_reports"

VENUE_KEYWORDS = [
    "체육관", "아트홀", "아트센터", "문예회관", "문화회관", "공연장", "컨벤션",
    "대학교", "체육공원", "실내체육관", "돔", "DOME", "ARENA", "아레나",
    "스타디움", "STADIUM", "짐나지움", "GYMNASIUM", "홀 ", " 홀", "센터",
]

FESTIVAL_HINTS = [
    "페스티벌", "FESTIVAL", "FES", "FES'", " x ", " X ", "×", " & ", "with ",
    " 콜라보", "합동", "연합",
]

NULL_LITERALS = {"null", "none", "n/a", "na", "unknown", "미상"}

# 한글 음절(가-힣) 옆에 한자(CJK 통합 한자)가 섞여있으면 대부분 정상적인 표기가 아니라
# 모델이 한글 음절을 시각적으로 비슷한(또는 임베딩 공간에서 가까운) 한자로 잘못 뱉은 것 -
# 실제로 KOPIS 원문 대조로 "내귀에도청장치"→"内귀에도청장치"(内=U+5185, 내=U+B0B4) 등
# 5건을 확정 오류로 확인함. 순수 한자 표기 밴드명(드물지만 존재)까지 걸러내려고
# "한글이 하나라도 섞여있을 때만" 걸리게 함 - 완전히 한자만으로 된 이름은 대상에서 제외.
_CJK_RE = re.compile(r"[一-鿿]")
_HANGUL_RE = re.compile(r"[가-힣]")


def load_rows(csv_path: Path) -> list[dict]:
    with open(csv_path, encoding="utf-8") as f:
        return list(csv.DictReader(f))


def check_venue_keyword(artists: list[str]) -> list[str]:
    hits = []
    for a in artists:
        for kw in VENUE_KEYWORDS:
            if kw.strip() and kw.strip() in a:
                hits.append(a)
                break
    return hits


def check_null_literal(artists: list[str]) -> list[str]:
    return [a for a in artists if a.strip().lower() in NULL_LITERALS]


def check_duplicate_artist_date(lineup: list[dict]) -> list[tuple]:
    seen = {}
    dups = []
    for entry in lineup:
        key = ((entry.get("artist") or "").strip(), entry.get("performance_date"))
        if key in seen:
            dups.append(key)
        seen[key] = True
    return dups


def check_festival_hint_single_artist(concert_name: str, unique_artist_count: int) -> bool:
    if unique_artist_count > 1:
        return False
    return any(hint.strip() and hint.lower() in concert_name.lower() for hint in FESTIVAL_HINTS)


def check_hanja_hangul_mix(artists: list[str]) -> list[str]:
    return [a for a in artists if _CJK_RE.search(a) and _HANGUL_RE.search(a)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv", default=str(LLM_SERVER_DIR / "test_concerts.csv"))
    parser.add_argument("--results-dir", default=str(LLM_SERVER_DIR / "batch_results"))
    args = parser.parse_args()

    rows = load_rows(Path(args.csv))
    results_dir = Path(args.results_dir)

    flagged = []
    missing = []
    clean = []

    for row in rows:
        kopis_id = row["kopis_id"]
        concert_name = row["concert_name"]
        json_path = results_dir / f"{kopis_id}.json"
        if not json_path.exists():
            missing.append((kopis_id, concert_name))
            continue

        data = json.loads(json_path.read_text(encoding="utf-8"))
        lineup = data.get("lineup", []) or []
        # artist가 진짜 JSON null로 오는 경우(스키마상 허용)도 있어 빈 문자열로 정규화
        artists = [e.get("artist") or "" for e in lineup]
        unique_artists = list(dict.fromkeys(a.strip() for a in artists if a.strip()))

        reasons = []

        venue_hits = check_venue_keyword(artists)
        if venue_hits:
            reasons.append(f"🔴공연장명의심({venue_hits})")

        null_hits = check_null_literal(artists)
        if null_hits:
            reasons.append(f"🟡null리터럴({null_hits})")

        dup_hits = check_duplicate_artist_date(lineup)
        if dup_hits:
            reasons.append(f"🟢중복({dup_hits})")

        if check_festival_hint_single_artist(concert_name, len(unique_artists)):
            reasons.append(f"🆕페스티벌/콜라보인데1명뿐({unique_artists})")

        hanja_hits = check_hanja_hangul_mix(artists)
        if hanja_hits:
            reasons.append(f"🈲한자혼입의심({hanja_hits})")

        if reasons:
            flagged.append((kopis_id, concert_name, reasons, unique_artists))
        else:
            clean.append((kopis_id, concert_name))

    print(f"전체 {len(rows)}건 / 결과파일 존재 {len(rows) - len(missing)}건 / 누락 {len(missing)}건")
    print(f"1차 스크리닝 걸림: {len(flagged)}건 / 정상통과: {len(clean)}건\n")

    if missing:
        print("=== 결과 JSON 누락 ===")
        for kopis_id, name in missing:
            print(f"  {kopis_id} | {name}")
        print()

    print("=== 1차 스크리닝 걸린 케이스 ===")
    for kopis_id, name, reasons, artists in flagged:
        print(f"[{kopis_id}] {name}")
        for r in reasons:
            print(f"    - {r}")
        print(f"    => 결과: {artists}")
    print()

    # 기계 판독용 CSV도 같이 저장
    DEFAULT_OUT_DIR.mkdir(parents=True, exist_ok=True)
    out_csv = DEFAULT_OUT_DIR / "screening_flagged.csv"
    with open(out_csv, "w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["kopis_id", "concert_name", "reasons", "unique_artists"])
        for kopis_id, name, reasons, artists in flagged:
            writer.writerow([kopis_id, name, " | ".join(reasons), ", ".join(artists)])
    print(f"플래그된 케이스 CSV로도 저장: {out_csv}")


if __name__ == "__main__":
    main()
