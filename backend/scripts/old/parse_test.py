"""
OCR 파싱 결과 확인용 스크립트

ocr_results.txt 에 저장된 OCR 텍스트에 _parse_ticket_fields() 를 적용해
각 필드 추출 결과를 터미널 및 parse_result.txt 파일에 출력합니다.

사용법:
    python scripts/parse_test.py
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from app.services.ocr import _parse_ticket_fields  # noqa: E402

_RESULT_FILE = Path(__file__).resolve().parent / "Image" / "ocr_results.txt"
_OUTPUT_FILE = Path(__file__).resolve().parent / "parse_result.txt"

_FIELDS = [
    ("title",         "제목     "),
    ("date",          "날짜     "),
    ("time",          "시간     "),
    ("shipping_date", "발송일   "),
    ("location",      "장소     "),
    ("seat",          "좌석     "),
    ("platform",      "플랫폼   "),
    ("price",         "금액     "),
    ("artist",        "아티스트 "),
    ("event_type",    "공연유형 "),
]


# ocr_results.txt → [(파일명, OCR 텍스트)] 목록
def _parse_sections(raw: str) -> list[tuple[str, str]]:
    sections = []
    current_file = None
    current_lines: list[str] = []

    for line in raw.splitlines():
        if line.startswith("파일:"):
            if current_file is not None:
                sections.append((current_file, "\n".join(current_lines).strip()))
            m = re.match(r"파일:\s+(\S+)", line)
            current_file = m.group(1) if m else "unknown"
            current_lines = []
        elif line.startswith("─") or line.startswith("═") or line.startswith("="):
            continue
        elif line.startswith("OCR 결과") or line.startswith("총 "):
            continue
        else:
            current_lines.append(line)

    if current_file is not None:
        sections.append((current_file, "\n".join(current_lines).strip()))

    return sections


# 필드 값 → 출력 문자열
def _fmt(key: str, value) -> str:
    if value is None:
        return "—"
    if key == "artist":
        return ", ".join(value) if value else "—"
    if key == "price":
        return f"{value:,}원"
    return str(value)


def main() -> None:
    if not _RESULT_FILE.exists():
        print(f"[오류] 결과 파일 없음: {_RESULT_FILE}")
        print("먼저 scripts/ocr_test.py 를 실행해 ocr_results.txt 를 생성하세요.")
        sys.exit(1)

    raw = _RESULT_FILE.read_text(encoding="utf-8")
    sections = _parse_sections(raw)

    if not sections:
        print("[오류] 파싱할 섹션이 없습니다.")
        sys.exit(1)

    lines: list[str] = [f"\nocr_results.txt 파싱 테스트 — {len(sections)}개 파일"]

    field_miss: dict[str, int] = {k: 0 for k, _ in _FIELDS}
    total_extracted = 0

    for filename, ocr_text in sections:
        result = _parse_ticket_fields(ocr_text)

        missing_keys = [k for k, _ in _FIELDS if result.get(k) in (None, [], "")]
        ok_count = len(_FIELDS) - len(missing_keys)
        total_extracted += ok_count
        for k in missing_keys:
            field_miss[k] += 1

        status = f"✓ {ok_count}/{len(_FIELDS)}" if not missing_keys else f"△ {ok_count}/{len(_FIELDS)}"
        lines.append(f"\n{'─' * 52}")
        lines.append(f"  {filename}  [{status}]")
        lines.append(f"{'─' * 52}")

        for key, label in _FIELDS:
            val = _fmt(key, result.get(key))
            marker = "  " if result.get(key) not in (None, [], "") else "? "
            lines.append(f"  {marker}{label}: {val}")

    # 전체 요약
    total = len(_FIELDS) * len(sections)
    rate = total_extracted / total * 100 if total else 0
    lines.append(f"\n{'═' * 52}")
    lines.append(f"  전체 추출률: {total_extracted}/{total}  ({rate:.0f}%)")
    lines.append(f"{'─' * 52}")
    lines.append("  필드별 미추출 횟수 (많을수록 파서 개선 필요)")
    for key, label in _FIELDS:
        miss = field_miss[key]
        bar = "■" * miss + "□" * (len(sections) - miss)
        lines.append(f"    {label}: {bar}  {miss}/{len(sections)}")
    lines.append(f"{'═' * 52}\n")

    output = "\n".join(lines)
    print(output)

    _OUTPUT_FILE.write_text(output, encoding="utf-8")
    print(f"[결과 저장] {_OUTPUT_FILE}")


if __name__ == "__main__":
    main()
