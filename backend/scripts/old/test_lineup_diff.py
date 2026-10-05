"""
실제 예매 사이트를 연속 두 번 크롤링해서, 라인업 변경 감지 로직(정규화된 텍스트 해시 +
이미지 목록)이 광고/좋아요수/조회수 같은 노이즈에 오탐하지 않는지 눈으로 확인하는 스크립트.

같은 페이지를 몇 초 간격으로 두 번 방문하면 실제 라인업은 절대 안 바뀌지만, 광고 배너나
실시간 카운터 같은 건 그 사이에도 바뀔 수 있음 - 두 방문의 원본 텍스트/이미지 목록을
그대로 비교(diff)해서 "무엇이 노이즈로 끼는지"를 먼저 보여주고, 그 다음 실제 배치가 쓰는
정규화(_hash_lineup_text/_normalize_lineup_img_srcs) 결과가 두 방문에서 같게 나오는지 보여줌.

사용법:
    python scripts/test_lineup_diff.py https://tickets.interpark.com/goods/12345
    python scripts/test_lineup_diff.py "[YES24] 그랜드 민트 페스티벌"
    python scripts/test_lineup_diff.py "[멜론] 인천펜타포트 락 페스티벌" --wait 10

지원 사이트: YES24, 인터파크, 멜론티켓
"""

import argparse
import asyncio
import difflib
import json
import logging
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace

# backend/.venv 로 자동 재실행 (어느 디렉터리에서 실행해도 동작)
_VENV_PYTHON = Path(__file__).resolve().parent.parent.parent / ".venv" / "Scripts" / "python.exe"
if _VENV_PYTHON.exists() and Path(sys.executable).resolve() != _VENV_PYTHON.resolve():
    sys.exit(subprocess.run([str(_VENV_PYTHON)] + sys.argv).returncode)

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from app.services.crawler import (  # noqa: E402
    _hash_lineup_text,
    _normalize_lineup_img_srcs,
    crawl_interpark,
    crawl_melon,
    crawl_yes24,
)

_OUT_DIR = Path(__file__).resolve().parent / "lineup_diff_cache"

_SITE_CRAWLERS = {
    "인터파크": crawl_interpark,
    "interpark": crawl_interpark,
    "yes24": crawl_yes24,
    "멜론": crawl_melon,
    "멜론티켓": crawl_melon,
    "melon": crawl_melon,
}

_SITE_QUERY_RE = re.compile(r"^\[(.+?)\]\s*(.+)$")


def _parse_site_query(text: str):
    m = _SITE_QUERY_RE.match(text.strip())
    if m:
        return m.group(1).strip(), m.group(2).strip()
    return None, None


def _slug(text: str) -> str:
    cleaned = re.sub(r"https?://", "", text)
    return re.sub(r"[^\w\-]", "_", cleaned).strip("_")[:80]


# 대상 한 번 방문 -> (screenshot, raw_text, text_hash, img_srcs) 반환
async def _visit(query: str, verbose: bool) -> tuple[bytes, str, str, list[str]]:
    site, concert_name = _parse_site_query(query)

    if site:
        crawler = _SITE_CRAWLERS.get(site.lower()) or _SITE_CRAWLERS.get(site)
        if crawler is None:
            print(f"[✗] 지원하지 않는 사이트: {site}", file=sys.stderr)
            sys.exit(1)
        concert = SimpleNamespace(name=concert_name)
        result = await crawler(concert, capture_lineup_snapshot=True)
    else:
        # URL을 어느 사이트에 넣을지 특정할 수 없으므로, URL 패턴으로 대충 유추
        if "interpark" in query:
            crawler = crawl_interpark
        elif "yes24" in query:
            crawler = crawl_yes24
        elif "melon" in query:
            crawler = crawl_melon
        else:
            print("[✗] URL만으로는 어느 사이트인지 유추할 수 없습니다. '[사이트명] 공연명' 형식을 쓰세요.", file=sys.stderr)
            sys.exit(1)
        concert = SimpleNamespace(name="(direct-url)")
        result = await crawler(concert, direct_url=query, capture_lineup_snapshot=True)

    if result is None:
        print(
            "[✗] 크롤링 실패 (None 반환) - 오픈 전/차단/검색결과 없음 등. "
            "-v(--verbose)를 붙이면 crawler.py의 실제 사유 로그가 보입니다.",
            file=sys.stderr,
        )
        sys.exit(1)

    return result


def _print_text_diff(text_a: str, text_b: str) -> bool:
    """두 원본 텍스트의 unified diff를 출력. 차이가 있었으면 True 반환"""
    lines_a = text_a.splitlines()
    lines_b = text_b.splitlines()
    diff = list(difflib.unified_diff(lines_a, lines_b, "1차 방문", "2차 방문", lineterm=""))
    if not diff:
        print("  (본문 텍스트 완전히 동일)")
        return False
    for line in diff:
        print(f"  {line}")
    return True


def _print_img_diff(imgs_a: list[str], imgs_b: list[str]) -> bool:
    only_a = sorted(set(imgs_a) - set(imgs_b))
    only_b = sorted(set(imgs_b) - set(imgs_a))
    if not only_a and not only_b:
        print("  (이미지 목록 완전히 동일)")
        return False
    for src in only_a:
        print(f"  - {src}")
    for src in only_b:
        print(f"  + {src}")
    return True


async def run(query: str, wait_seconds: int, verbose: bool) -> None:
    if verbose:
        logging.basicConfig(level=logging.INFO, format="%(message)s")

    print(f"[1차 방문] {query}")
    screenshot_a, text_a, hash_a, imgs_a = await _visit(query, verbose)
    print(f"  본문 길이: {len(text_a)}자, 이미지(정규화 후): {len(imgs_a)}개")

    if wait_seconds > 0:
        print(f"\n[대기] {wait_seconds}초 후 재방문...")
        await asyncio.sleep(wait_seconds)

    print(f"\n[2차 방문] {query}")
    screenshot_b, text_b, hash_b, imgs_b = await _visit(query, verbose)
    print(f"  본문 길이: {len(text_b)}자, 이미지(정규화 후): {len(imgs_b)}개")

    print("\n" + "━" * 60)
    print("  원본 텍스트 diff (정규화 전 - 광고/카운터 노이즈가 그대로 보임)")
    print("━" * 60)
    raw_text_changed = _print_text_diff(text_a, text_b)

    print("\n" + "━" * 60)
    print("  이미지 목록 diff (정규화 후 - 광고 도메인 필터 + 쿼리스트링 제거 적용됨)")
    print("━" * 60)
    img_changed = _print_img_diff(imgs_a, imgs_b)

    print("\n" + "━" * 60)
    print("  실제 배치가 쓰는 판단 결과")
    print("━" * 60)
    print(f"  정규화된 텍스트 해시:  {'동일' if hash_a == hash_b else '다름 (!)'}  ({hash_a[:12]}... vs {hash_b[:12]}...)")
    print(f"  정규화된 이미지 목록:  {'동일' if imgs_a == imgs_b else '다름 (!)'}")
    would_flag_changed = hash_a != hash_b or imgs_a != imgs_b
    print(f"  → 라인업 재크롤링 배치라면: {'변경으로 판단 (새 스크린샷 업로드)' if would_flag_changed else '변경 없음으로 판단 (스킵)'}")

    if raw_text_changed and hash_a == hash_b:
        print("\n  [✓] 원본 텍스트는 달랐지만(광고/카운터 등) 정규화 후엔 같게 나옴 - 필터링이 의도대로 작동")
    if raw_text_changed and hash_a != hash_b:
        print("\n  [!] 원본 텍스트도 다르고 정규화 후에도 다름 - 실제 라인업이 바뀐 게 아니라면 노이즈 필터가 이 케이스를 못 잡고 있는 것")

    # 나중에 다시 살펴볼 수 있도록 원본 텍스트/이미지 목록을 그대로 저장
    _OUT_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_path = _OUT_DIR / f"{timestamp}_{_slug(query)}.json"
    out_path.write_text(
        json.dumps(
            {
                "query": query,
                "wait_seconds": wait_seconds,
                "visit_1": {"text": text_a, "hash": hash_a, "img_srcs": imgs_a},
                "visit_2": {"text": text_b, "hash": hash_b, "img_srcs": imgs_b},
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    print(f"\n[✓] 원본 텍스트/이미지 목록 저장: {out_path.resolve()}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="같은 예매 페이지를 두 번 크롤링해 라인업 변경 감지의 노이즈 오탐 여부를 확인",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("query", help="URL 또는 '[사이트명] 공연명'")
    parser.add_argument("--wait", type=int, default=5, help="1차/2차 방문 사이 대기 시간(초). 기본 5초")
    parser.add_argument("--verbose", "-v", action="store_true", help="상세 로그 출력")

    args = parser.parse_args()
    try:
        asyncio.run(run(args.query, args.wait, args.verbose))
    except KeyboardInterrupt:
        print("\n[!] 중단됨")
        sys.exit(1)
