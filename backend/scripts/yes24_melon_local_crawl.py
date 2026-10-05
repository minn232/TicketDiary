"""YES24/멜론 링크만 있고 인터파크가 없는 공연(자동 크롤링 대상에서 빠짐 - AWS 서버 IP가
YES24/멜론에 차단당해 _TEMPORARILY_DISABLED_SITES로 막아둔 상태)의 "최초 크롤링"(배송일/
티켓팅일은 실제 예매 사이트 페이지에만 있어서 KOPIS 폴백으론 못 얻음)을 이 컴퓨터(데이터센터가
아닌 일반 네트워크)에서 대신 수행하는 스크립트.

크롤링 로직 자체는 재구현하지 않고 app.services.crawler의 crawl_yes24/crawl_melon을 그대로
가져와 쓴다(사이트 DOM이 바뀌면 서버 쪽 크롤러를 고치는 게 이 스크립트에도 자동으로 반영됨).
이 스크립트가 하는 일은:
  1. 서버에서 대상 목록 조회 (GET /admin/crawl-targets/yes24-melon)
  2. 각 공연을 이 컴퓨터 네트워크로 직접 크롤링 (실패하면 다음 후보 사이트로, 그래도 실패하면 스킵)
  3. 성공한 스크린샷을 서버로 업로드 (POST /admin/crawl-targets/{id}/screenshot)
     - 서버가 S3 업로드 + crawl_screenshot_url 갱신까지 처리함(이 컴퓨터엔 AWS 자격증명이
       전혀 필요 없음, admin API 키만 있으면 됨)
  4. 업로드된 스크린샷을 실제로 읽어 배송일/티켓팅일을 뽑는 건 별도 LLM 분석 단계의 몫 -
     이 스크립트만 돌려서는 안 채워짐, 이어서 LLM 배치를 한 번 태워야 함

서버 주소/admin 키는 기본값으로 박아둬서 그냥 실행만 하면 됨 (backend 디렉토리, venv 활성화된 상태):
    python scripts/yes24_melon_local_crawl.py --dry-run   # 실제 크롤링/업로드 없이 대상 건수·목록만 확인
    python scripts/yes24_melon_local_crawl.py --limit 30  # 하루 30건 정도로 나눠서(권장) - 이미
                                                           # 성공한 건은 대상 목록에서 자동으로 빠지므로
                                                           # 다음날 다시 같은 명령을 그대로 실행하면 됨
    python scripts/yes24_melon_local_crawl.py --delay 60  # 건당 대기 시간(초) 기본값(33s, ±40% 흔들림)보다
                                                           # 더 여유 있게 잡고 싶을 때
    python scripts/yes24_melon_local_crawl.py --new-only  # LLM 분석 배치가 밀려 예전에 크롤링한 건이
                                                           # 계속 대상에 남아있을 때, 그런 건 빼고 진짜
                                                           # 신규(스크린샷 자체가 없는 것)만 대상으로 함

시간이 급하지 않으면 --limit으로 적당히 나눠서 며칠에 걸쳐 돌리는 걸 추천함(133건이면 하루
30건씩 4~5일 정도). 다른 서버/키를 쓰고 싶으면 --base-url/--admin-key(또는
TICKETDIARY_API_BASE_URL/TICKETDIARY_ADMIN_KEY 환경변수)로 덮어쓸 수 있음.

사전 준비: 이 컴퓨터에도 Playwright 크로미움이 설치돼있어야 함(최초 1회만):
    playwright install chromium
"""

import argparse
import os
import random
import sys
import time
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import httpx  # noqa: E402

from app.services.crawler import _CRAWLERS  # noqa: E402

# 매번 타이핑하기 귀찮아서 기본값으로 박아둠(--base-url/--admin-key로 언제든 덮어쓸 수 있음).
# scripts/ 자체가 .gitignore 대상이라 git에는 안 올라가지만, 이 파일을 다른 곳에 복사해서
# 옮기면 이 키도 같이 옮겨간다는 점은 인지하고 쓸 것(admin API 전체 권한 키라 노트북을
# 잃어버리는 것 같은 상황이면 서버 .env의 ADMIN_API_KEY를 새 값으로 바꿔야 함)
# admin.ticket-diary.com은 nginx Basic Auth로 막혀있어서(브라우저 로그인 전용) 스크립트에서
# 그대로 호출하면 X-Admin-Key와 무관하게 401이 남 - Basic Auth가 없는 메인 도메인으로 접근
_DEFAULT_BASE_URL = "https://ticket-diary.com/api/v1"
_DEFAULT_ADMIN_KEY = "c76c6eac2eb3b04974a53c34a039d842a772311e88bb7ab44db40ee744dfc985"

# 요청 간 기본 대기(초) - 집 IP라도 짧은 시간에 몰아치면 똑같이 의심받을 수 있으니 여유를 둠.
# 시간이 급하지 않다면 33s(30~45s 범위 중간값) 정도로 넉넉하게 잡는 게 안전함
_DEFAULT_DELAY_SECONDS = 33.0
# 매번 정확히 같은 간격이면 그 자체로 패턴이 되므로 ±40% 범위에서 흔들어줌(사람이 손으로
# 다음 걸 확인하고 넘어가는 것처럼) - 아예 안 기다리는 경우가 없도록 최소 40%는 항상 보장
_DELAY_JITTER_RATIO = 0.4


def _fetch_targets(base_url: str, admin_key: str, new_only: bool) -> list[dict]:
    resp = httpx.get(
        f"{base_url}/admin/crawl-targets/yes24-melon",
        headers={"X-Admin-Key": admin_key},
        params={"exclude_already_crawled": new_only} if new_only else None,
        timeout=30.0,
    )
    resp.raise_for_status()
    return resp.json()["items"]


def _upload_result(base_url: str, admin_key: str, concert_id: str, site: str, image_bytes: bytes) -> None:
    resp = httpx.post(
        f"{base_url}/admin/crawl-targets/{concert_id}/screenshot",
        headers={"X-Admin-Key": admin_key},
        params={"site": site},
        files={"image": ("screenshot.png", image_bytes, "image/png")},
        timeout=30.0,
    )
    resp.raise_for_status()


async def _crawl_one(target: dict) -> tuple[str, bytes] | None:
    fake_concert = SimpleNamespace(name=target["name"])
    for candidate in target["candidates"]:
        site, url = candidate["site"], candidate["url"]
        crawler = _CRAWLERS.get(site)
        if crawler is None:
            print(f"  [스킵] {target['name']}: 지원 안 하는 사이트({site})")
            continue
        print(f"  시도: {target['name']} ({site})")
        image_bytes = await crawler(fake_concert, direct_url=url)
        if image_bytes is not None:
            return site, image_bytes
        print(f"    -> 실패({site}), 다음 후보로")
    return None


async def main(
    base_url: str, admin_key: str, delay: float, limit: int | None, dry_run: bool, new_only: bool
) -> None:
    targets = _fetch_targets(base_url, admin_key, new_only)
    if limit:
        targets = targets[:limit]
    print(f"대상 {len(targets)}건")

    if dry_run:
        for i, target in enumerate(targets, 1):
            sites = "/".join(c["site"] for c in target["candidates"])
            print(f"  [{i}] {target['name']} ({target['kopis_id'] or target['concert_id']}) - 시도할 사이트: {sites}")
        print("\n--dry-run이라 실제 크롤링/업로드는 하지 않았습니다.")
        return

    ok, fail = 0, 0
    failed_targets: list[str] = []
    for i, target in enumerate(targets, 1):
        label = f"{target['name']} ({target['kopis_id'] or target['concert_id']})"
        print(f"[{i}/{len(targets)}] {label}")
        try:
            result = await _crawl_one(target)
            if result is None:
                print("  -> 전부 실패, 스킵")
                fail += 1
                failed_targets.append(label)
            else:
                site, image_bytes = result
                _upload_result(base_url, admin_key, target["concert_id"], site, image_bytes)
                print(f"  -> 성공({site}), 업로드 완료")
                ok += 1
        except Exception as e:
            # 한 건이 예상 못한 이유로 죽어도(업로드 크기 초과 등) 전체 배치가 중단되면 안 됨 -
            # 이 건만 건너뛰고 나머지는 계속 진행. 실패 목록은 마지막에 다시 보여줌
            print(f"  -> 예외로 실패, 스킵: {e}")
            fail += 1
            failed_targets.append(label)
        if i < len(targets):
            wait = delay * random.uniform(1 - _DELAY_JITTER_RATIO, 1 + _DELAY_JITTER_RATIO)
            time.sleep(wait)

    print(f"\n완료: 성공 {ok}건, 실패 {fail}건")
    if failed_targets:
        print("실패한 건:")
        for label in failed_targets:
            print(f"  - {label}")
    if ok:
        print("성공한 건들은 배송일/티켓팅일이 아직 안 뽑힌 상태 - LLM 분석 배치를 이어서 돌려야 실제로 채워짐.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--base-url", default=os.environ.get("TICKETDIARY_API_BASE_URL", _DEFAULT_BASE_URL), required=False
    )
    parser.add_argument(
        "--admin-key", default=os.environ.get("TICKETDIARY_ADMIN_KEY", _DEFAULT_ADMIN_KEY), required=False
    )
    parser.add_argument("--delay", type=float, default=_DEFAULT_DELAY_SECONDS, help="공연 간 대기 시간(초)")
    parser.add_argument("--limit", type=int, default=None, help="테스트용 - 앞에서 N건만 처리")
    parser.add_argument(
        "--dry-run", action="store_true", help="실제로 크롤링/업로드하지 않고 대상 건수와 목록만 확인"
    )
    parser.add_argument(
        "--new-only",
        action="store_true",
        help=(
            "이미 로컬 크롤링을 마쳐 스크린샷을 올린 건(crawl_screenshot_url 있음)은 "
            "제외하고, 진짜 아직 한 번도 안 건드린 공연만 대상으로 함 - LLM 분석 배치가 "
            "밀려서 예전에 크롤링한 건이 계속 대상에 남아있을 때, 매크로 탐지 위험을 "
            "피하려고 같은 공연을 또 크롤링하지 않게 함"
        ),
    )
    args = parser.parse_args()

    if not args.base_url or not args.admin_key:
        print("--base-url/--admin-key(또는 TICKETDIARY_API_BASE_URL/TICKETDIARY_ADMIN_KEY 환경변수)가 필요합니다.", file=sys.stderr)
        sys.exit(1)

    import asyncio

    asyncio.run(
        main(args.base_url.rstrip("/"), args.admin_key, args.delay, args.limit, args.dry_run, args.new_only)
    )
