"""PF299785(MADLY MEDLEY) 아티스트명 병합 배치 중 _collapse_members_to_group_names의
로스터 1명짜리 "그룹" 버그(수정: app/services/artist_normalization.py)로 "Hukky Shibaseki"가
무관한 "LEMON"으로 뒤바뀐 걸 되돌리는 일회용 스크립트. 근본 원인은 코드에서 고쳤고(로스터
2명 미만이면 통합 안 함), 이 스크립트는 이미 잘못 반영된 이 콘서트 한 건만 정정한다.

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/old/fix_pf299785_lemon_collapse_bug.py
"""

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from sqlalchemy import select  # noqa: E402

from app.core.database import AsyncSessionLocal  # noqa: E402
from app.models.concert import Concert  # noqa: E402


async def main() -> None:
    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Concert).where(Concert.kopis_id == "PF299785"))
        concert = result.scalar_one_or_none()
        if concert is None:
            print("PF299785를 찾을 수 없음")
            return

        names = list(concert.artist_name or [])
        print(f"수정 전: {names}")
        if "LEMON" not in names:
            print("이미 LEMON이 없음, 변경 없이 종료")
            return

        names = [n for n in names if n != "LEMON"]
        if "Hukky Shibaseki" not in names:
            names.append("Hukky Shibaseki")
        concert.artist_name = sorted(names)
        await db.commit()
        print(f"수정 후: {concert.artist_name}")


if __name__ == "__main__":
    asyncio.run(main())
