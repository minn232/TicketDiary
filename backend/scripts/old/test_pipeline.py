"""
티켓 사진/예매내역 캡처 → OCR → KOPIS 검색 → 크롤링 통합 테스트 스크립트

실제 서버(/concerts/scan)와 동일하게 Vision 응답 1건으로 좌표 기반 격자 파싱을
먼저 시도하고, 격자로 인식 안 되면(라벨 부족) 기존 regex 파싱으로 자동 폴백한다.
어떤 경로로 추출됐는지는 STEP 2 로그의 "추출 방식"에 표시됨.

사용법:
    python scripts/test_pipeline.py <이미지경로 또는 폴더경로>
    python scripts/test_pipeline.py ticket.jpg           # 카메라로 찍은 티켓
    python scripts/test_pipeline.py booking_capture.png  # 예매내역/상세내역 캡처
    python scripts/test_pipeline.py ticket.jpg --verbose
    python scripts/test_pipeline.py Crawling            # 폴더 안 이미지 전부 순차 실행
"""

import argparse
import asyncio
import hashlib
import json
import logging
import re
import subprocess
import sys
from datetime import datetime, date
from pathlib import Path

# backend/.venv 로 자동 재실행
_VENV_PYTHON = Path(__file__).resolve().parent.parent.parent / ".venv" / "Scripts" / "python.exe"
if _VENV_PYTHON.exists() and Path(sys.executable).resolve() != _VENV_PYTHON.resolve():
    sys.exit(subprocess.run([str(_VENV_PYTHON)] + sys.argv).returncode)

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.services.ocr import (  # noqa: E402
    _call_vision,
    _full_text_from_annotation,
    _parse_ticket_fields,
    _parse_ticket_fields_from_layout,
    _to_jpeg,
)
from app.services.kopis import search_concerts_multi, get_concert_detail  # noqa: E402
from app.services.crawler import (  # noqa: E402
    _pick_crawl_target,
    _CRAWLERS,
    crawl_kopis,
)

_IMAGE_DIR = Path(__file__).resolve().parent / "Image"

_CONTENT_TYPE_MAP = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".heic": "image/heic",
    ".heif": "image/heif",
    ".webp": "image/webp",
}

_SEP = "─" * 60

# Windows 파일명 금지 문자 (콜론은 특히 NTFS 대체 데이터 스트림으로 해석되어
# "파일명:나머지" 형태로 잘리고 실제 내용은 숨겨진 스트림에 들어가 0바이트처럼 보임)
_ILLEGAL_FILENAME_CHARS = re.compile(r'[<>:"/\\|?*]')

# OCR 캐시: 같은 이미지를 재실행할 때 Google Vision API를 다시 호출하지 않도록
# 이미지 바이트의 sha256 해시를 키로 Vision 응답 원본(annotation, bbox 포함)을 저장한다
# (필드 파싱 결과가 아님). 파싱(_parse_ticket_fields/_parse_ticket_fields_from_layout)은
# 로컬 순수 함수라 매번 새로 돌려도 비용이 없고, 그래야 파싱 로직을 고쳤을 때 캐시를
# 지우지 않아도 바로 반영된다.
# 예매내역 캡처(좌표 기반 격자 파싱) 지원 이전엔 "원본 텍스트만" 문자열로 저장했었는데,
# 그 구버전 캐시 항목은 bbox가 없어 격자 파싱은 자동으로 스킵되고 regex 경로로만 재현됨
# (하위호환 - 기존 캐시를 지우지 않아도 계속 쓸 수 있음)
_OCR_CACHE_PATH = Path(__file__).resolve().parent / "ocr_raw_text_cache.json"


def _load_ocr_cache() -> dict:
    if _OCR_CACHE_PATH.exists():
        return json.loads(_OCR_CACHE_PATH.read_text(encoding="utf-8"))
    return {}


# 캐시 항목을 annotation dict로 정규화 (구버전 문자열 캐시는 text만 있는 annotation으로 감쌈)
def _as_annotation(cached) -> dict:
    if isinstance(cached, dict):
        return cached
    return {"fullTextAnnotation": {"text": cached}}


def _save_ocr_cache(cache: dict) -> None:
    _OCR_CACHE_PATH.write_text(
        json.dumps(cache, ensure_ascii=False, indent=2), encoding="utf-8"
    )


# 파이프라인 실패 시 원본 OCR 텍스트 + 파싱된 필드를 txt로 남겨서, OCR 자체가 잘못 읽은 건지
# 파싱(_LABEL_SKIP 등) 로직이 잘못 골라낸 건지 원문을 직접 보고 구분할 수 있게 함
_FAILED_OCR_DIR = Path(__file__).resolve().parent / "failed_ocr"


def _save_failed_ocr_dump(image_path: Path, raw_text: str, ocr_result: dict, reason: str) -> None:
    _FAILED_OCR_DIR.mkdir(parents=True, exist_ok=True)
    out_path = _FAILED_OCR_DIR / f"{image_path.stem}.txt"
    content = (
        f"이미지: {image_path.name}\n"
        f"실패 사유: {reason}\n"
        f"\n"
        f"── 파싱된 필드 (_parse_ticket_fields) ──\n"
        f"{json.dumps(ocr_result, ensure_ascii=False, indent=2)}\n"
        f"\n"
        f"── Vision API 원본 텍스트 ──\n"
        f"{raw_text}\n"
    )
    out_path.write_text(content, encoding="utf-8")
    print(f"  [i] 실패 OCR 덤프 저장: {out_path.resolve()}", file=sys.stderr)


# 단일 이미지 파이프라인 실패 (배치 모드에서 이 예외만 잡아 다음 이미지로 계속 진행)
class _PipelineError(Exception):
    pass


def _log(label: str, value):
    print(f"  {label:<16} {value}")


def _section(title: str):
    print(f"\n{'━' * 60}")
    print(f"  {title}")
    print(f"{'━' * 60}")


def _fail(msg: str):
    print(f"  [✗] {msg}", file=sys.stderr)
    raise _PipelineError(msg)


async def run_pipeline(image_path: Path, verbose: bool, refresh: bool = False) -> None:
    if verbose:
        logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    # ── STEP 1: 이미지 로드 ──────────────────────────────────────
    _section("STEP 1 — 티켓 이미지 로드")
    if not image_path.exists():
        _fail(f"파일 없음: {image_path}")

    image_bytes = image_path.read_bytes()
    content_type = _CONTENT_TYPE_MAP.get(image_path.suffix.lower(), "image/jpeg")
    _log("파일", image_path.name)
    _log("크기", f"{len(image_bytes) / 1024:.1f} KB")
    _log("content-type", content_type)

    # ── STEP 2: OCR ──────────────────────────────────────────────
    _section("STEP 2 — OCR (Google Vision API)")
    image_hash = hashlib.sha256(image_bytes).hexdigest()
    ocr_cache = _load_ocr_cache()
    # 좌표(bbox) 지원 이전에 캐시된 구버전(텍스트만) 항목은 --refresh 없이는 격자 파싱을
    # 검증할 수 없음 (bbox가 없어 항상 None -> regex로 폴백) - 경고로 알려줌
    cached = ocr_cache.get(image_hash)
    is_legacy_cache = cached is not None and not isinstance(cached, dict)
    if cached is not None and not refresh:
        annotation = _as_annotation(cached)
        print("  [캐시] Vision API 응답 재사용 (API 호출 생략)")
        if is_legacy_cache:
            print("  [!] 구버전 캐시(bbox 없음) - 좌표 기반 격자 파싱은 항상 스킵됨. "
                  "검증하려면 --refresh로 재실행", file=sys.stderr)
    else:
        try:
            loop = asyncio.get_running_loop()
            jpeg_bytes = await loop.run_in_executor(None, _to_jpeg, image_bytes, content_type)
            annotation = await _call_vision(jpeg_bytes)
        except Exception as e:
            _fail(f"OCR 실패: {e}")
        ocr_cache[image_hash] = annotation
        _save_ocr_cache(ocr_cache)

    try:
        raw_text = _full_text_from_annotation(annotation)
    except Exception as e:
        _fail(f"OCR 실패: {e}")

    # 실제 /concerts/scan과 동일한 순서: 좌표 기반 격자(예매내역 캡처) 우선 시도,
    # 라벨이 부족해 격자로 인식 안 되면 기존 regex 파싱으로 폴백
    layout_result = _parse_ticket_fields_from_layout(annotation, raw_text)
    if layout_result is not None:
        ocr_result = layout_result
        extraction_mode = "좌표 기반 격자 (예매내역 캡처)"
    else:
        ocr_result = _parse_ticket_fields(raw_text)
        extraction_mode = "regex (모바일 티켓 등)"

    _log("추출 방식",     extraction_mode)
    _log("공연명",        ocr_result.get("title") or "(미추출)")
    _log("공연 날짜",     ocr_result.get("date") or "(미추출)")
    _log("공연 시간",     ocr_result.get("time") or "(미추출)")
    _log("공연장",        ocr_result.get("location") or "(미추출)")
    _log("좌석",          ocr_result.get("seat") or "(미추출)")
    _log("가격",          f"{ocr_result.get('price'):,}원" if ocr_result.get("price") else "(미추출)")
    _log("예매 플랫폼",   ocr_result.get("platform") or "(미추출)")
    _log("발송 예정일",   ocr_result.get("shipping_date") or "(미추출)")

    # STEP 3 이후 실패하면(_PipelineError) 원본 텍스트+파싱 필드를 txt로 남겨서
    # OCR이 잘못 읽은 건지 파싱 로직이 잘못 골라낸 건지 나중에 직접 비교해볼 수 있게 함
    try:
        title = ocr_result.get("title")
        if not title:
            _fail("공연명을 추출할 수 없어 KOPIS 검색을 진행할 수 없습니다.")

        platform = ocr_result.get("platform")
        location = ocr_result.get("location")
        # title 하나로 실패하면 원본 텍스트의 다른 후보 줄들로 순서대로 재시도
        # (예: "빨래는 오늘을 살아가는"으로 실패 -> 원본 텍스트 뒷줄의 "빨래"로 재시도)
        title_candidates = ocr_result.get("title_candidates") or [title]

        # 날짜 범위 설정 (공연 날짜 ±90일)
        concert_date_str = ocr_result.get("date")
        start_date = end_date = None
        if concert_date_str:
            try:
                from datetime import timedelta
                cd = date.fromisoformat(concert_date_str)
                start_date = cd - timedelta(days=90)
                end_date   = cd + timedelta(days=90)
            except ValueError:
                pass

        # ── STEP 3: KOPIS 검색 ───────────────────────────────────
        _section("STEP 3 — KOPIS API 검색")
        _log("날짜 범위", f"{start_date} ~ {end_date}" if start_date else "제한 없음")
        _log("검색어 후보", f"{len(title_candidates)}개 ({title_candidates[:5]}{'...' if len(title_candidates) > 5 else ''})")

        async with AsyncSessionLocal() as db:
            try:
                concerts = await search_concerts_multi(
                    db, title_candidates, start_date, end_date, location
                )
            except Exception as e:
                _fail(f"KOPIS 검색 실패: {e}")

        if not concerts:
            _fail(f"KOPIS에서 검색 결과 없음 (제목 후보 {len(title_candidates)}개 전부 미발견)")

        print(f"  검색 결과: {len(concerts)}건")
        for i, c in enumerate(concerts[:5]):
            marker = "▶" if i == 0 else " "
            start = c.start_date.strftime('%Y-%m-%d') if c.start_date else '?'
            end   = c.end_date.strftime('%Y-%m-%d') if c.end_date else '?'
            print(f"  {marker} [{i+1}] {c.name}  ({start} ~ {end})  kopis_id={c.kopis_id}")

        concert = concerts[0]
        print(f"\n  → 첫 번째 결과 선택: {concert.name}")

        # ── STEP 4: KOPIS 상세 조회 (ticketing_links 포함) ───────
        _section("STEP 4 — KOPIS 상세 조회")
        async with AsyncSessionLocal() as db:
            try:
                concert = await get_concert_detail(db, concert.kopis_id)
            except Exception as e:
                _fail(f"KOPIS 상세 조회 실패: {e}")

        _log("공연명",     concert.name)
        _log("장소",       concert.venue or "(없음)")
        _log("기간",       f"{concert.start_date.strftime('%Y-%m-%d')} ~ {concert.end_date.strftime('%Y-%m-%d')}")
        _log("아티스트",   ", ".join(concert.artist_name) if concert.artist_name else "(없음)")
        _log("kopis_id",   concert.kopis_id)
        _log("예매 링크",  str(concert.ticketing_links) if concert.ticketing_links else "(없음)")

        # ── STEP 5: 크롤링 대상 결정 ──────────────────────────────
        _section("STEP 5 — 크롤링 대상 결정")

        ticketing_site = platform or "TICKETLINK"
        _log("OCR 플랫폼", ticketing_site)

        site_key, direct_url = _pick_crawl_target(ticketing_site, concert.ticketing_links)
        if site_key is None:
            _log("크롤링 방식", "KOPIS 페이지 폴백 (티켓링크 미지원)")
        else:
            _log("크롤링 대상", site_key)
            _log("직접 URL", direct_url or "(이름 검색 방식)")

        # ── STEP 6: 크롤링 ────────────────────────────────────────
        _section("STEP 6 — 크롤링")

        if site_key is None:
            print(f"  [→] KOPIS 상세 페이지 캡처 중...")
            image_out = await crawl_kopis(concert)
            label = "kopis"
        else:
            crawler = _CRAWLERS.get(site_key)
            if crawler is None:
                _fail(f"크롤러 없음: {site_key}")
            print(f"  [→] {site_key} 크롤링 중...")
            image_out = await crawler(concert, direct_url=direct_url)
            label = site_key.lower()

        if image_out is None:
            _fail("크롤링 실패 (None 반환)")

        # ── 결과 저장 ──────────────────────────────────────────────
        _section("완료")
        _IMAGE_DIR.mkdir(parents=True, exist_ok=True)
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        safe_name = _ILLEGAL_FILENAME_CHARS.sub("_", concert.name[:30]).replace(" ", "_")
        out_path = _IMAGE_DIR / f"{timestamp}_{safe_name}_{label}.png"
        out_path.write_bytes(image_out)

        # 파일명에 남은 문제 문자가 있으면(ADS로 해석되는 등) 디스크상 크기가 메모리 크기와 어긋남 → 즉시 경고
        written_size = out_path.stat().st_size
        if written_size != len(image_out):
            _fail(
                f"저장된 파일 크기가 일치하지 않음 (기대 {len(image_out)}바이트, 실제 {written_size}바이트): "
                f"{out_path} — 파일명에 처리 안 된 특수문자가 남아있을 수 있음"
            )

        print(f"  [✓] 저장 완료: {out_path.resolve()}")
        print(f"       크기: {len(image_out) / 1024:.1f} KB")
        print()
    except _PipelineError as e:
        _save_failed_ocr_dump(image_path, raw_text, ocr_result, str(e))
        raise


# 폴더 안의 이미지 전부를 순서대로 파이프라인 실행 (한 장이 실패해도 나머지는 계속 진행)
async def run_batch(image_paths: list[Path], verbose: bool, refresh: bool = False) -> None:
    results: list[tuple[str, bool]] = []
    for i, path in enumerate(image_paths, 1):
        print(f"\n{'#' * 60}")
        print(f"  [{i}/{len(image_paths)}] {path.name}")
        print(f"{'#' * 60}")
        try:
            await run_pipeline(path, verbose, refresh)
            results.append((path.name, True))
        except _PipelineError:
            results.append((path.name, False))

    _section("배치 결과 요약")
    for name, ok in results:
        print(f"  {'✓' if ok else '✗'} {name}")
    success_count = sum(ok for _, ok in results)
    print(f"\n  총 {len(results)}건 중 {success_count}건 성공, {len(results) - success_count}건 실패")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="티켓 이미지 → OCR → KOPIS → 크롤링 통합 테스트",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("image", help="티켓 이미지 파일 경로 또는 이미지가 담긴 폴더 경로")
    parser.add_argument("--verbose", "-v", action="store_true", help="상세 로그 출력")
    parser.add_argument(
        "--refresh", action="store_true",
        help="캐시가 있어도 Vision API를 다시 호출 (구버전 텍스트 전용 캐시로는 좌표 기반 "
             "격자 파싱을 검증할 수 없어서 필요)",
    )

    args = parser.parse_args()
    target = Path(args.image)
    if not target.exists():
        # 실행 위치(cwd)에 없으면 스크립트 자신의 위치(scripts/) 기준으로도 찾아봄
        fallback = Path(__file__).resolve().parent / args.image
        if fallback.exists():
            target = fallback

    try:
        if target.is_dir():
            images = sorted(
                p for p in target.iterdir()
                if p.is_file() and p.suffix.lower() in _CONTENT_TYPE_MAP
            )
            if not images:
                print(f"[✗] 폴더에 이미지가 없습니다: {target}", file=sys.stderr)
                sys.exit(1)
            asyncio.run(run_batch(images, args.verbose, args.refresh))
        else:
            asyncio.run(run_pipeline(target, args.verbose, args.refresh))
    except _PipelineError:
        sys.exit(1)
    except KeyboardInterrupt:
        print("\n[!] 중단됨")
        sys.exit(1)
