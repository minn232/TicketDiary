"""주간 KOPIS 교차검증 QA 스크립트.

[[artist_extraction_next_steps_2026-08-23]] 3번(주기적 KOPIS 교차검증)의 실제 구현체.
DB에 저장된 concert.artist_name(LLM 추출 결과가 반영된 최종값)을 KOPIS 원본(prfcast)과
공연 제목 두 소스와 대조해서, 둘 다와 안 겹치는 이름만 의심 케이스로 CSV에 남긴다.

**DB를 자동으로 고치지 않는다** - 과거 리뷰 기준 적중률이 33~39%라(플래그된 것 중 다수는
오탐) 사람이 CSV를 보고 포스터와 직접 대조 후 확정된 것만 반영해야 함. 4체크 스크리닝
(llm_server/screen_batch_results.py)이 놓치는 유형(로고 오독, 할루시네이션처럼 공연장
키워드도 페스티벌 힌트도 없는 케이스)을 잡기 위한 것 - 그 스크리닝을 대체하는 게 아니라
보완하는 용도.

주의: concert.artist_name은 소규모 공연에서 LLM 결과가 오면 KOPIS 원본을 완전히
덮어써서(artist_matching.py의 merge_artist_names replace=True 경로) DB엔 원본이 더 이상
안 남아있다. 그래서 비교 시점마다 KOPIS 상세 API를 다시 호출해 prfcast를 즉석으로
가져온다 - sync_daily_concerts와 동일한 전역 스로틀(kopis.py의 _throttle_kopis_request,
초당 ~2.8회)을 그대로 재사용하므로 1,300건도 약 8분이면 끝나고 별도 레이트리밋 로직이
필요 없다.

사용법 (서버에서, 매주 cron으로 돌리는 걸 염두에 둠):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/kopis_cross_check.py                # 최근 7일 이내 추출분 대상
    venv/bin/python3 scripts/kopis_cross_check.py --days 30      # 기간 조정(첫 베이스라인 등)
    venv/bin/python3 scripts/kopis_cross_check.py --limit 50     # 소규모 테스트
    venv/bin/python3 scripts/kopis_cross_check.py --out qa_reports/custom.csv
"""

import argparse
import asyncio
import csv
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

import httpx  # noqa: E402
from fastapi import HTTPException  # noqa: E402
from rapidfuzz import fuzz  # noqa: E402
from sqlalchemy import func, select  # noqa: E402

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.concert import Concert  # noqa: E402
from app.services.artist_matching import _romanization_match  # noqa: E402
from app.services.kopis import _fetch_kopis_detail_data  # noqa: E402

_WHITESPACE_RE = re.compile(r"\s+")


# 공백/대소문자 흔들림만 흡수(exact 동일성을 요구하지 않음) - 부분표기 차이는 fuzzy로 따로 처리
def _normalize(text: str) -> str:
    return _WHITESPACE_RE.sub("", text).casefold()


# artist_matching.py의 _FUZZY_MATCH_THRESHOLD(92, DB 자동병합용)보다 살짝 낮게 잡음 - 여기는
# 자동 병합이 아니라 "의심 후보 추리기"라 놓치는 것보다 과다플래그가 안전함
_MATCH_THRESHOLD = 88


# name이 제목/KOPIS원본 둘 중 하나와 겹치면 정상으로 간주(True). 부분 포함(콤마로 쪼개진
# 멤버명 등)과 fuzzy 유사도(표기 흔들림) 둘 다 허용
def _is_covered(name: str, title: str, kopis_artists: list[str]) -> bool:
    norm_name = _normalize(name)
    if not norm_name:
        return True
    if norm_name in _normalize(title):
        return True
    for kopis_name in kopis_artists:
        norm_kopis = _normalize(kopis_name)
        if not norm_kopis:
            continue
        if norm_name in norm_kopis or norm_kopis in norm_name:
            return True
        if fuzz.ratio(norm_name, norm_kopis) >= _MATCH_THRESHOLD:
            return True
    # 제목/KOPIS 둘 다 원문 비교로는 안 걸렸어도 한글↔로마자 표기 차이일 수 있음(예: 제목은
    # "KIM SIHUN"인데 뽑힌 이름은 "김시훈") - artist_matching.py가 DB 병합에 쓰는 것과 같은
    # 로마자 변환 매칭을 재사용해 이 유형의 오탐(정답인데 표기만 달라 플래그되는 것)을 줄임
    if _romanization_match(name, set(kopis_artists)) is not None:
        return True
    return False


def _target_query(since: datetime):
    return select(Concert).where(
        Concert.kopis_id.isnot(None),
        Concert.artist_extraction_attempted_at.isnot(None),
        Concert.artist_extraction_attempted_at >= since,
        func.cardinality(Concert.artist_name) > 0,
    )


async def main(days: int, limit: int | None, out_path: Path) -> None:
    since = datetime.now(timezone.utc) - timedelta(days=days)

    async with AsyncSessionLocal() as db:
        query = _target_query(since)
        if limit:
            query = query.limit(limit)
        concerts = list((await db.execute(query)).scalars().all())

    print(f"대상 공연: {len(concerts)}건 (최근 {days}일 이내 아티스트 추출분)")
    if not concerts:
        print("대상이 없어 종료합니다.")
        return

    flagged: list[dict] = []
    failed: list[str] = []

    # 상세 API는 kopis.py 내부 전역 스로틀(_throttle_kopis_request)을 이미 태우므로
    # 여기서 별도 동시성 제어 없이 순차 호출 - concurrency를 올려도 스로틀 락 때문에
    # 처리량이 안 늘어남(초당 ~2.8건이 상한)
    async with httpx.AsyncClient(timeout=10.0) as client:
        for i, concert in enumerate(concerts, 1):
            try:
                data = await _fetch_kopis_detail_data(client, concert.kopis_id)
            except HTTPException as e:
                failed.append(f"{concert.kopis_id} ({e.detail})")
                continue
            except Exception as e:
                failed.append(f"{concert.kopis_id} ({e})")
                continue

            title = data.get("name") or ""
            kopis_artists = data.get("artist_name") or []

            for name in concert.artist_name or []:
                if not _is_covered(name, title, kopis_artists):
                    flagged.append(
                        {
                            "kopis_id": concert.kopis_id,
                            "concert_name": title,
                            "suspicious_artist": name,
                            "db_artist_name": ", ".join(concert.artist_name or []),
                            "kopis_artist_name": ", ".join(kopis_artists),
                        }
                    )

            if i % 100 == 0:
                print(f"  진행: {i}/{len(concerts)}")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=["kopis_id", "concert_name", "suspicious_artist", "db_artist_name", "kopis_artist_name"],
        )
        writer.writeheader()
        writer.writerows(flagged)

    print(f"\n조회 완료: {len(concerts)}건 / 재조회 실패: {len(failed)}건 / 의심 케이스: {len(flagged)}건")
    if failed:
        print("재조회 실패 목록 (KOPIS에서 내려갔거나 장르가 바뀐 경우일 수 있음):")
        for f_ in failed[:20]:
            print(f"  {f_}")
        if len(failed) > 20:
            print(f"  ... 외 {len(failed) - 20}건")
    print(f"의심 케이스 CSV 저장: {out_path}")
    print("주의: 자동 수정 안 됨 - 사람이 CSV 열어서 포스터 직접 대조 후 확정된 것만 반영할 것")
    print("      (과거 리뷰 기준 적중률 33~39%, 플래그된 것의 다수는 오탐)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--days", type=int, default=7, help="최근 N일 이내 아티스트 추출분만 대상 (기본 7일)")
    parser.add_argument("--limit", type=int, default=None, help="대상 공연 수 제한 (테스트용)")
    parser.add_argument(
        "--out",
        type=Path,
        default=None,
        help="결과 CSV 경로 (기본: qa_reports/kopis_cross_check_YYYYMMDD.csv)",
    )
    args = parser.parse_args()

    default_out = (
        Path(__file__).resolve().parent.parent.parent
        / "qa_reports"
        / f"kopis_cross_check_{datetime.now().strftime('%Y%m%d')}.csv"
    )
    asyncio.run(main(args.days, args.limit, args.out or default_out))
