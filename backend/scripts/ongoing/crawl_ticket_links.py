"""
티켓 예매 링크(URL) 여러 개를 한 번에 크롤링해서 상세페이지 스크린샷으로 저장하는 스크립트.

백엔드 서버(uvicorn)나 DB 연결 없이, app.services.crawler의 크롤링 함수만 그대로 재사용해서
Playwright로 직접 페이지를 열고 스크린샷만 로컬 파일로 뽑아낸다. LLM팀에 넘길 크롤링 이미지가
부족할 때, 여러 페스티벌/공연 예매 링크를 한 번에 밀어넣어 빠르게 이미지를 모으기 위한 용도.

사용법:
    # URL 1개
    python scripts/crawl_ticket_links.py https://ticket.yes24.com/Perf/58933

    # URL 여러 개 (커맨드라인에 나열)
    python scripts/crawl_ticket_links.py <url1> <url2> <url3>

    # 파일로 일괄 처리 (한 줄에 URL 하나, '#'로 시작하는 줄은 주석)
    python scripts/crawl_ticket_links.py links.txt

    # URL과 파일 섞어서 지정도 가능
    python scripts/crawl_ticket_links.py links.txt https://ticket.yes24.com/Perf/58933 --verbose

지원 사이트: YES24/인터파크/멜론티켓은 전용 크롤러(오픈전 페이지/멜론 Kakao 봇차단 감지 포함)를
쓰고, 그 외 도메인(KOPIS 상세페이지, 네이버 예약 등)은 범용 스크린샷(crawl_url)으로 폴백한다.
티켓링크(ticketlink.co.kr)는 Akamai 봇 차단으로 크롤링 자체가 불가능해 자동 스킵된다
(backend/scripts/TICKETLINK_CRAWLING_RESEARCH.md 참고).

결과: scripts/Image/<타임스탬프>_<슬러그>.png (--dir로 변경 가능)
"""

import argparse
import asyncio
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
    crawl_interpark,
    crawl_melon,
    crawl_url,
    crawl_yes24,
)

_IMAGE_DIR = Path(__file__).resolve().parent / "Image"

# URL에 이 문자열이 포함되면 해당 전용 크롤러 사용(오픈전/봇차단 감지 포함) - 첫 매치 사용
_SITE_CRAWLERS_BY_DOMAIN = [
    ("yes24.com", crawl_yes24),
    ("interpark.com", crawl_interpark),
    ("melon.com", crawl_melon),
]

_TICKETLINK_DOMAIN = "ticketlink.co.kr"


def _slug(url: str) -> str:
    cleaned = re.sub(r"https?://", "", url)
    return re.sub(r"[^\w\-]", "_", cleaned).strip("_")[:80]


# 인자로 받은 각 target을 URL 목록으로 펼침 - 존재하는 파일 경로면 한 줄당 URL 하나로 읽고,
# 그냥 URL 문자열이면 1개짜리로 취급 (URL과 파일 경로를 섞어서 넘겨도 됨)
def _expand_targets(targets: list[str]) -> list[str]:
    urls: list[str] = []
    for target in targets:
        path = Path(target)
        if path.exists() and path.is_file():
            for line in path.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if line and not line.startswith("#"):
                    urls.append(line)
        else:
            urls.append(target.strip())
    return urls


def _pick_crawler(url: str):
    for domain, crawler in _SITE_CRAWLERS_BY_DOMAIN:
        if domain in url:
            return crawler
    return None


async def _crawl_one(url: str, wait_ms: int, verbose: bool) -> bytes | None:
    if _TICKETLINK_DOMAIN in url:
        print("  [✗] 티켓링크는 크롤링 불가(Akamai 봇 차단) - 스킵")
        return None

    crawler = _pick_crawler(url)
    if crawler is not None:
        # 전용 크롤러는 direct_url 방식일 때 concert.name을 로그 문구에만 사용하므로
        # DB 조회 없이 SimpleNamespace로 흉내만 내면 충분함 (capture_screenshot.py와 동일 패턴)
        concert = SimpleNamespace(name=url)
        return await crawler(concert, direct_url=url)

    return await crawl_url(url, wait_ms=wait_ms, verbose=verbose)


async def run(urls: list[str], out_dir: Path, wait_ms: int, verbose: bool) -> None:
    if verbose:
        logging.basicConfig(level=logging.INFO, format="%(message)s")

    out_dir.mkdir(parents=True, exist_ok=True)
    results: list[tuple[str, bool]] = []

    for i, url in enumerate(urls, 1):
        print(f"\n[{i}/{len(urls)}] {url}")
        image_bytes = await _crawl_one(url, wait_ms, verbose)
        if image_bytes is None:
            print("  [✗] 크롤링 실패")
            results.append((url, False))
            continue

        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
        out_path = out_dir / f"{timestamp}_{_slug(url)}.png"
        out_path.write_bytes(image_bytes)
        print(f"  [✓] 저장: {out_path.resolve()}  ({len(image_bytes) / 1024:.1f} KB)")
        results.append((url, True))

    print(f"\n{'─' * 60}")
    success = sum(ok for _, ok in results)
    print(f"총 {len(results)}건 중 {success}건 성공, {len(results) - success}건 실패")
    if success < len(results):
        print("실패 목록:")
        for url, ok in results:
            if not ok:
                print(f"  - {url}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="티켓 예매 링크 → 자동 크롤링 → 스크린샷 저장 (서버/DB 불필요)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "targets", nargs="+",
        help="URL 1개 이상, 또는 URL 목록이 한 줄씩 담긴 파일 경로 (섞어서 지정 가능)",
    )
    parser.add_argument("--dir", help="출력 디렉터리 (기본값: scripts/Image/)")
    parser.add_argument("--wait", type=int, default=2000, help="범용 크롤링(crawl_url) 시 추가 대기(ms)")
    parser.add_argument("--verbose", "-v", action="store_true", help="상세 로그 출력")

    args = parser.parse_args()
    urls = _expand_targets(args.targets)
    if not urls:
        print("[✗] 처리할 URL이 없습니다.", file=sys.stderr)
        sys.exit(1)

    out_dir = Path(args.dir) if args.dir else _IMAGE_DIR

    try:
        asyncio.run(run(urls, out_dir, args.wait, args.verbose))
    except KeyboardInterrupt:
        print("\n[!] 중단됨")
        sys.exit(1)
