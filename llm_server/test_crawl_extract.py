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
모인다. report.html은 공연마다 포스터 이미지와 추출 결과를 나란히 보여주는 한 장짜리 리포트라,
파일을 일일이 열지 않고 이미지와 값을 바로 대조할 수 있다(실패/경고 있는 건이 위로 올라오고
검색/경고 코드 필터가 있음). 브라우저로 열면 되고, 이미지는 screenshot_url을 그대로 불러온다.

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
    /workspace/venv/bin/python server/test_crawl_extract.py server/llm_crawl_samples.json --report-only --run-name before  # 저장된 결과로 report.html만 다시 만들기

    
"""

import argparse
import csv
import html
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

_WARNING_LABELS = {
    "C1": "거의 빈 결과",
    "C2": "아티스트 없음",
    "C3": "아티스트명 이상",
    "C4": "시간표 이상",
    "C5": "가격 이상",
    "C6": "날짜 이상",
    "C7": "오래 걸림",
}

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


def _row_from_disk(sample: dict, out_dir: Path) -> dict | None:
    """--resume으로 건너뛴 건을 리포트에 넣기 위해, 저장된 callback.json으로 행을 복원한다.
    경고는 규칙 기반이라 다시 계산하면 되고, 걸린 시간은 알 수 없어 None."""
    path = out_dir / f"{sample['concert_id']}.callback.json"
    if not path.exists():
        return None
    callback = json.loads(path.read_text(encoding="utf-8"))
    return {
        "concert_id": sample["concert_id"],
        "sample": sample,
        "callback": callback,
        "warnings": _evaluate_warnings(callback, sample),
        "elapsed": None,
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


# ── report.html: 포스터 이미지와 추출 결과를 공연별 카드로 나란히 보여주는 한 장짜리 리포트 ──
_REPORT_CSS = """
:root{--bg:#f6f4f0;--card:#fff;--ink:#222;--sub:#777;--line:#e4e0d8;--warn:#b45309;--warnbg:#fef3c7;--err:#b91c1c;--errbg:#fee2e2;--ok:#166534;--okbg:#dcfce7;--chip:#eee9df}
@media(prefers-color-scheme:dark){:root{--bg:#1c1b19;--card:#262522;--ink:#eee;--sub:#aaa;--line:#3a3834;--warn:#fbbf24;--warnbg:#44340f;--err:#fca5a5;--errbg:#451a1a;--ok:#86efac;--okbg:#14351f;--chip:#34322e}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.5 system-ui,"Malgun Gothic",sans-serif}
header{position:sticky;top:0;z-index:5;background:var(--bg);border-bottom:1px solid var(--line);padding:12px 16px}
h1{font-size:17px;margin:0 0 6px}.meta{color:var(--sub);font-size:13px}
.bar{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px;align-items:center}
.bar input{padding:6px 10px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--ink);min-width:200px}
.pill{border:1px solid var(--line);background:var(--card);color:var(--ink);padding:3px 10px;border-radius:14px;cursor:pointer;font-size:13px}
.pill.on{background:var(--ink);color:var(--bg)}
main{max-width:1100px;margin:0 auto;padding:12px 16px 60px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;margin:14px 0;overflow:hidden}
.card.err{border-color:var(--err)}.card.warned{border-color:var(--warn)}
.head{padding:10px 14px;border-bottom:1px solid var(--line);display:flex;flex-wrap:wrap;gap:8px;align-items:center}
.head b{font-size:15px}.sub{color:var(--sub);font-size:12px}
.badge{font-size:12px;padding:1px 8px;border-radius:10px;background:var(--warnbg);color:var(--warn)}
.badge.err{background:var(--errbg);color:var(--err)}.badge.ok{background:var(--okbg);color:var(--ok)}
.body{display:grid;grid-template-columns:minmax(220px,38%) 1fr;gap:14px;padding:14px}
.poster img{width:100%;border-radius:6px;border:1px solid var(--line);display:block}
.poster .nolink{color:var(--sub);font-size:12px}
@media(max-width:720px){.body{grid-template-columns:1fr}}
h3{font-size:13px;margin:12px 0 4px;color:var(--sub)}h3:first-child{margin-top:0}
.warnlist{margin:0 0 4px;padding:8px 10px 8px 26px;background:var(--warnbg);color:var(--warn);border-radius:6px}
.chips span{display:inline-block;background:var(--chip);border-radius:12px;padding:1px 9px;margin:2px 4px 2px 0}
table{border-collapse:collapse;width:100%;font-size:13px}th,td{border-bottom:1px solid var(--line);padding:3px 8px;text-align:left}
th{color:var(--sub);font-weight:600}td.bad{color:var(--err);font-weight:600}.empty{color:var(--sub)}
.scroll{max-height:320px;overflow:auto;border:1px solid var(--line);border-radius:6px}
pre{white-space:pre-wrap;word-break:break-all;background:var(--errbg);color:var(--err);padding:8px;border-radius:6px;margin:0}
"""

_REPORT_JS = """
const cards=[...document.querySelectorAll('.card')];
let code='',onlyWarn=false;
const q=document.getElementById('q');
function apply(){const t=q.value.trim().toLowerCase();let n=0;
cards.forEach(c=>{const ok=(!t||c.dataset.name.includes(t))&&(!onlyWarn||c.dataset.codes||c.dataset.err)&&(!code||c.dataset.codes.split(' ').includes(code)||(code==='ERR'&&c.dataset.err));
c.style.display=ok?'':'none';if(ok)n++});document.getElementById('shown').textContent=n}
q.oninput=apply;
document.querySelectorAll('.pill').forEach(b=>b.onclick=()=>{
if(b.dataset.code!==undefined){code=code===b.dataset.code?'':b.dataset.code}else{onlyWarn=!onlyWarn}
document.querySelectorAll('.pill').forEach(x=>x.classList.toggle('on',x.dataset.code!==undefined?x.dataset.code===code:onlyWarn));apply()});
"""


def _e(value) -> str:
    return html.escape("" if value is None else str(value))


def _table(headers: list[str], rows: list[list], bad_cols: dict[int, set] | None = None) -> str:
    if not rows:
        return '<div class="empty">없음</div>'
    out = ["<table><tr>" + "".join(f"<th>{_e(h)}</th>" for h in headers) + "</tr>"]
    for row in rows:
        cells = []
        for i, v in enumerate(row):
            bad = bad_cols and v in bad_cols.get(i, ())
            cells.append(f'<td class="bad">{_e(v)}</td>' if bad else f"<td>{_e(v)}</td>")
        out.append("<tr>" + "".join(cells) + "</tr>")
    out.append("</table>")
    return "".join(out)


def _card_html(row: dict) -> str:
    sample = row["sample"]
    name = sample.get("concert_name") or row["concert_id"]
    url = sample.get("screenshot_url")
    poster = (
        f'<a href="{_e(url)}" target="_blank" rel="noopener"><img loading="lazy" src="{_e(url)}" alt="포스터"></a>'
        if url
        else '<div class="nolink">이미지 URL 없음</div>'
    )
    meta = [sample.get("event_type"), f"{sample.get('start_date') or '?'} ~ {sample.get('end_date') or '?'}"]
    ranges = sample.get("timetable_ranges")
    if ranges:
        meta.append(f"구간 {len(ranges)}개")
    if row["elapsed"] is not None:
        meta.append(f"{row['elapsed']:.1f}초")
    head = f'<b>{_e(name)}</b><span class="sub">{_e(" · ".join(str(m) for m in meta if m))}</span>'

    if row["error"] is not None:
        return (
            f'<section class="card err" data-name="{_e(name.lower())}" data-codes="" data-err="1">'
            f'<div class="head">{head}<span class="badge err">실패</span></div>'
            f'<div class="body"><div class="poster">{poster}</div>'
            f"<div><h3>오류</h3><pre>{_e(row['error'])}</pre></div></div></section>"
        )

    cb = row["callback"]
    warnings = row["warnings"]
    codes = sorted({c for c, _ in warnings})
    badges = "".join(f'<span class="badge">{c} {_e(_WARNING_LABELS.get(c, ""))}</span>' for c in codes)
    if not warnings:
        badges = '<span class="badge ok">경고 없음</span>'

    parts = []
    if warnings:
        items = "".join(f"<li><b>{_e(c)}</b> {_e(d)}</li>" for c, d in warnings)
        parts.append(f'<h3>경고</h3><ul class="warnlist">{items}</ul>')

    artists = cb.get("artist_name") or []
    chips = "".join(f"<span>{_e(a)}</span>" for a in artists)
    parts.append(
        f"<h3>아티스트 ({len(artists)})</h3>" + (f'<div class="chips">{chips}</div>' if chips else '<div class="empty">없음</div>')
    )

    start, end = _parse_date(sample.get("start_date")), _parse_date(sample.get("end_date"))
    timetable = cb.get("timetable") or []
    bad_dates = {
        e.get("date")
        for e in timetable
        if (d := _parse_date(e.get("date"))) and start and end and not (start <= d <= end)
    }
    bad_times = {e.get("time") for e in timetable if e.get("time") and not _TIME_RE.match(e["time"])}
    tt_rows = [[e.get("date"), e.get("time"), e.get("stage"), e.get("event")] for e in timetable]
    parts.append(
        f"<h3>시간표 ({len(timetable)})</h3>"
        '<div class="scroll">'
        + _table(["날짜", "시간", "스테이지", "아티스트/이벤트"], tt_rows, {0: bad_dates, 1: bad_times, 3: {"라인업 미공개"}})
        + "</div>"
    )

    prices = cb.get("prices") or []
    bad_prices = {p.get("price") for p in prices if p.get("price") is not None and not (1000 <= p["price"] <= 1_000_000)}
    parts.append(
        f"<h3>가격 ({len(prices)})</h3>"
        + _table(["좌석", "가격"], [[p.get("seat_type"), p.get("price")] for p in prices], {1: bad_prices})
    )

    phases = cb.get("ticketing_phases") or []
    info_rows = [["예매 시작(가장 이른)", cb.get("ticketing_date") or "-"]]
    info_rows += [[f"· {p.get('phase')}", p.get("date") or "-"] for p in phases]
    info_rows += [["티켓 배송일", cb.get("delivery_date") or "-"], ["음식 반입", cb.get("food_allowed") or "-"]]
    parts.append("<h3>예매/기타</h3>" + _table(["항목", "값"], info_rows))

    lineup = cb.get("lineup") or []
    if lineup:
        parts.append(
            f"<h3>라인업 ({len(lineup)})</h3>"
            '<div class="scroll">'
            + _table(["아티스트", "출연일"], [[x.get("artist"), x.get("performance_date")] for x in lineup])
            + "</div>"
        )

    cls = "card warned" if warnings else "card"
    return (
        f'<section class="{cls}" data-name="{_e(name.lower())}" data-codes="{" ".join(codes)}" data-err="">'
        f'<div class="head">{head}{badges}</div>'
        f'<div class="body"><div class="poster">{poster}</div><div>{"".join(parts)}</div></div></section>'
    )


def _write_report_html(out_dir: Path, run_name: str, rows: list[dict]) -> None:
    # 실패 → 경고 많은 순 → 경고 없음 순으로 올려 확인할 건을 앞에 둔다(같은 그룹은 입력 순서 유지)
    def key(item: tuple[int, dict]) -> tuple:
        i, r = item
        if r["error"] is not None:
            return (0, 0, i)
        return (1, -len(r["warnings"]), i) if r["warnings"] else (2, 0, i)

    ordered = [r for _, r in sorted(enumerate(rows), key=key)]
    counts: dict[str, int] = {}
    for r in rows:
        if r["error"] is None:
            for code in {c for c, _ in r["warnings"]}:
                counts[code] = counts.get(code, 0) + 1
    failed = sum(1 for r in rows if r["error"] is not None)
    warned = sum(1 for r in rows if r["error"] is None and r["warnings"])

    pills = '<button class="pill" type="button">경고 있는 건만</button>'
    if failed:
        pills += f'<button class="pill" type="button" data-code="ERR">실패 {failed}</button>'
    for code in sorted(counts):
        label = _e(_WARNING_LABELS.get(code, ""))
        pills += f'<button class="pill" type="button" data-code="{code}">{code} {label} {counts[code]}</button>'
    legend = " · ".join(f"{c} {label}" for c, label in _WARNING_LABELS.items())

    doc = (
        '<!doctype html><html lang="ko"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        f"<title>크롤 추출 리포트 {_e(run_name)}</title><style>{_REPORT_CSS}</style></head><body>"
        f"<header><h1>크롤 추출 리포트 · {_e(run_name)}</h1>"
        f'<div class="meta">총 {len(rows)}건 · 실패 {failed} · 경고 {warned} · 표시 <span id="shown">{len(rows)}</span>건</div>'
        f'<div class="meta">{_e(legend)} (경고는 채점이 아니라 확인 힌트, 빨간 값은 규칙에 걸린 값)</div>'
        f'<div class="bar"><input id="q" placeholder="공연명 검색">{pills}</div></header>'
        f'<main>{"".join(_card_html(r) for r in ordered)}</main><script>{_REPORT_JS}</script></body></html>'
    )
    (out_dir / "report.html").write_text(doc, encoding="utf-8")
    print(f"리포트: {out_dir}/report.html (브라우저로 열기)")


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

    # 이번에 안 돌리고 저장된 결과로 리포트에만 넣을 건(--resume으로 건너뛴 건, --report-only 전체)
    carried: list[dict] = []
    if args.resume or args.report_only:
        before = len(samples)
        pending = []
        for s in samples:
            row = _row_from_disk(s, out_dir)
            if row is not None:
                carried.append(row)
            else:
                pending.append(s)
        if args.report_only:
            print(f"--report-only: 저장된 {len(carried)}건으로 리포트만 만듦({before - len(carried)}건은 결과 없음)")
            _write_report_html(out_dir, run_name, carried)
            return
        samples = pending
        print(f"--resume: {before}건 중 {len(carried)}건은 이미 완료돼 건너뜀, {len(samples)}건만 실행")

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
    _write_report_html(out_dir, run_name, carried + results)
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
    parser.add_argument(
        "--report-only", action="store_true", help="추출 없이 out-dir/run-name에 저장된 결과로 report.html만 다시 만듦"
    )
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
