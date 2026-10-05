"""
URL 또는 [사이트명] 공연명 형식으로 스크린샷을 저장하는 스크립트.

사용법:
    # 직접 URL - 스크린샷
    python scripts/capture_screenshot.py https://ticket.yes24.com/Perf/57553

    # [사이트] 공연명 - 검색 후 스크린샷
    python scripts/capture_screenshot.py "[인터파크] 아이유 콘서트"
    python scripts/capture_screenshot.py "[YES24] 아이유 콘서트"

지원 사이트: YES24, 인터파크, 멜론티켓 (티켓링크 미지원)

결과 파일: scripts/Image/<타임스탬프>_<슬러그>.png  (기본값)
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

from sqlalchemy import select  # noqa: E402

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.concert import Concert  # noqa: E402
from app.services.crawler import (  # noqa: E402
    crawl_interpark,
    crawl_kopis,
    crawl_melon,
    crawl_url,
    crawl_yes24,
)

_IMAGE_DIR = Path(__file__).resolve().parent / "Image"

_SITE_CRAWLERS = {
    "인터파크": crawl_interpark,
    "interpark": crawl_interpark,
    "yes24": crawl_yes24,
    "멜론": crawl_melon,
    "멜론티켓": crawl_melon,
    "melon": crawl_melon,
}

_TICKETLINK_SITES = {"티켓링크", "ticketlink"}

_SITE_QUERY_RE = re.compile(r"^\[(.+?)\]\s*(.+)$")


async def _crawl_ticketlink_via_kopis(concert_name: str) -> bytes | None:
    """DB에서 공연명으로 concert 조회 → kopis_id로 KOPIS 페이지 캡처."""
    print(f"[→] 티켓링크 미지원 → DB에서 '{concert_name}' 검색 후 KOPIS 페이지 캡처")
    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(Concert).where(Concert.name.ilike(f"%{concert_name}%"))
        )
        concert = result.scalars().first()

    if concert is None:
        print(f"[✗] DB에서 공연을 찾을 수 없습니다: {concert_name}", file=sys.stderr)
        return None

    if not concert.kopis_id:
        print(f"[✗] KOPIS ID 없음 — 캡처 불가: {concert.name}", file=sys.stderr)
        return None

    print(f"[✓] 공연 발견: {concert.name}  (kopis_id={concert.kopis_id})")
    kopis_url = (
        f"https://kopis.or.kr/por/db/pblprfr/pblprfrView.do"
        f"?menuId=MNU_00099&mt20Id={concert.kopis_id}"
    )
    print(f"[→] KOPIS 페이지 캡처: {kopis_url}")
    return await crawl_kopis(concert)


def _parse_site_query(text: str):
    m = _SITE_QUERY_RE.match(text.strip())
    if m:
        return m.group(1).strip(), m.group(2).strip()
    return None, None


def _slug(text: str) -> str:
    cleaned = re.sub(r"https?://", "", text)
    return re.sub(r"[^\w\-]", "_", cleaned).strip("_")[:80]


async def run_screenshot(query: str, output_path: Path, wait_ms: int, verbose: bool) -> None:
    if verbose:
        logging.basicConfig(level=logging.INFO, format="%(message)s")

    site, concert_name = _parse_site_query(query)

    if site:
        if site.lower() in _TICKETLINK_SITES:
            image_bytes = await _crawl_ticketlink_via_kopis(concert_name)
        else:
            crawler = _SITE_CRAWLERS.get(site.lower()) or _SITE_CRAWLERS.get(site)
            if crawler is None:
                print(f"[✗] 지원하지 않는 사이트: {site}", file=sys.stderr)
                sys.exit(1)
            concert = SimpleNamespace(name=concert_name)
            print(f"[→] '{site}' 에서 '{concert_name}' 검색 후 캡처")
            image_bytes = await crawler(concert)
    else:
        if "ticketlink.co.kr" in query:
            print("[✗] 티켓링크는 크롤링을 지원하지 않습니다 (Akamai 봇 차단)", file=sys.stderr)
            sys.exit(1)
        print(f"[→] 캡처 중: {query}")
        image_bytes = await crawl_url(query, wait_ms=wait_ms, verbose=verbose)

    if image_bytes is None:
        print("[✗] 스크린샷 캡처 실패", file=sys.stderr)
        sys.exit(1)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(image_bytes)
    print(f"[✓] 저장 완료: {output_path.resolve()}  ({len(image_bytes) / 1024:.1f} KB)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="URL 또는 [사이트명] 공연명으로 스크린샷/이미지 캡처",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("query", help="URL 또는 '[사이트명] 공연명'")
    parser.add_argument("-o", "--output", help="저장할 파일 경로 (스크린샷 모드, 미지정 시 자동 생성)")
    parser.add_argument("--dir", help="출력 디렉터리 (기본값: scripts/Image/)")
    parser.add_argument("--wait", type=int, default=2000, help="추가 대기(ms). 스크린샷 URL 방식에만 적용.")
    parser.add_argument("--verbose", "-v", action="store_true", help="상세 로그 출력")

    args = parser.parse_args()
    out_dir = Path(args.dir) if args.dir else _IMAGE_DIR

    try:
        if args.output:
            output_path = Path(args.output)
        else:
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            output_path = out_dir / f"{timestamp}_{_slug(args.query)}.png"
        asyncio.run(run_screenshot(args.query, output_path, args.wait, args.verbose))
    except KeyboardInterrupt:
        print("\n[!] 중단됨")
        sys.exit(1)
