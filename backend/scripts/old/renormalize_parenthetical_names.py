"""괄호 병기 아티스트 표기("넬 (NELL)", "내귀에도청장치 (Wiretap in my ear)")를 다시 정규화하는 일회용 스크립트.

괄호 밖/병기 이름으로도 찾도록 _process_one이 바뀌기 전에 unconfirmed/ambiguous로 끝난 행을
pending으로 되돌리고 그 공연들만 normalize_specific_artists로 다시 돌림. 같은 공연에 "넬"과
"넬 (NELL)"이 같이 있으면 정규화 결과로 하나로 합쳐짐(apply_canonical_replacement가 set으로 합침).

사용법 (서버에서, 괄호 처리 코드 배포 후):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/old/renormalize_parenthetical_names.py --dry-run   # 대상만 확인
    venv/bin/python3 scripts/old/renormalize_parenthetical_names.py
"""

import argparse
import asyncio
import sys
from collections import defaultdict
from pathlib import Path

_BACKEND_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_BACKEND_ROOT))

from sqlalchemy import select  # noqa: E402

from app.core.database import AsyncSessionLocal, engine  # noqa: E402
from app.models.artist_normalization import ArtistNormalizationStatus  # noqa: E402
from app.models.concert import Concert  # noqa: E402
from app.services.artist_normalization import normalize_specific_artists  # noqa: E402

engine.echo = False  # 서버 설정이 SQL을 전부 찍어서 진행 로그가 묻힘


async def main(dry_run: bool) -> None:
    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(ArtistNormalizationStatus, Concert.artist_name)
            .join(Concert, Concert.id == ArtistNormalizationStatus.concert_id)
            .where(
                ArtistNormalizationStatus.artist_text.like("%(%)%"),
                ArtistNormalizationStatus.status.in_(["unconfirmed", "ambiguous"]),
            )
        )
        by_concert: dict = defaultdict(list)
        for row, artist_name in result.all():
            # 이미 다른 이름으로 바뀌어 공연에 없는 표기는 건너뜀
            if row.artist_text in (artist_name or []):
                by_concert[row.concert_id].append(row)

        total = sum(len(rows) for rows in by_concert.values())
        print(f"대상: 공연 {len(by_concert)}개, 표기 {total}개")
        for rows in by_concert.values():
            for row in rows:
                print(f"  [{row.status}] {row.artist_text}")
        if dry_run:
            return

        for rows in by_concert.values():
            for row in rows:
                row.status = "pending"
        await db.commit()

    totals: dict[str, int] = defaultdict(int)
    for concert_id, rows in by_concert.items():
        stats = await normalize_specific_artists(concert_id, [row.artist_text for row in rows])
        for key, value in stats.items():
            totals[key] += value
    print(f"결과: {dict(totals)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    asyncio.run(main(parser.parse_args().dry_run))
