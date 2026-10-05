"""LLM팀이 pod에서 크롤링 분석(extract_poster_info)을 실서비스 연동 전에 미리 테스트해볼 수
있게, crawl_screenshot_url이 있는 진행예정 공연 전부를 JSON으로 뽑아 넘겨주는 스크립트.

DB에 아무것도 쓰지 않는 읽기 전용 스크립트다. LLM팀은 llm_server/test_crawl_extract.py로 이
JSON을 읽어 extract_poster_info + normalize_crawl_result를 직접 호출해서 돌려본다(HTTP로
/crawl-analyze를 거치면 콜백이 실서버로 가서 crawl_result_received_at이 찍히고 배치 대상에서
빠지는 부작용이 있어 그 경로는 안 씀 - test_batch_extract.py와 같은 이유).

검수 여부(admin_reviewed_at 등)로 거르지 않는다 - DB에 쓰는 게 없어서 이미 검수된 공연이
섞여도 문제없고, 테스트 표본은 많을수록 좋다.

건별로 다음을 담는다:
  - concert_id/concert_name/screenshot_url/timetable_ranges: 실제 전송 페이로드
    (CrawlAnalyzeItem)와 동일 - 테스트 스크립트가 그대로 넣어 쓸 수 있게
  - event_type/start_date/end_date: LLM팀이 표본을 취사선택하거나 날짜 경고를 판정할 때 쓰는
    부가 정보(실제 전송 페이로드에는 없음)

timetable_ranges가 null이면 아직 계산 안 된 것, []이면 계산됐지만 구간이 없는 것이다(둘 다
구간 없이 처리됨 - extract_poster_info 참고).

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/ongoing/export_llm_crawl_samples.py                        # 기본 out/llm_crawl_samples.json
    venv/bin/python3 scripts/ongoing/export_llm_crawl_samples.py --out samples.json
"""

import argparse
import asyncio
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from sqlalchemy import select  # noqa: E402

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.concert import Concert  # noqa: E402


async def _fetch_samples() -> list[dict]:
    now = datetime.now(timezone.utc)
    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(Concert).where(
                Concert.crawl_screenshot_url.isnot(None),
                Concert.end_date > now,
            )
        )
        concerts = list(result.scalars().all())

    return [
        {
            "concert_id": str(c.id),
            "concert_name": c.name,
            "screenshot_url": c.crawl_screenshot_url,
            "timetable_ranges": c.timetable_ranges,
            "event_type": c.event_type,
            "start_date": c.start_date.date().isoformat() if c.start_date else None,
            "end_date": c.end_date.date().isoformat() if c.end_date else None,
        }
        for c in concerts
    ]


async def main(out_path: Path) -> None:
    samples = await _fetch_samples()

    with_ranges = sum(1 for s in samples if s["timetable_ranges"])
    print(f"대상 {len(samples)}건 (구간 있음 {with_ranges}, 없음/미계산 {len(samples) - with_ranges})")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(samples, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"저장: {out_path}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default="out/llm_crawl_samples.json", help="출력 JSON 경로")
    args = parser.parse_args()

    asyncio.run(main(Path(args.out)))
