"""
KOPIS 상세 조회 400 에러의 실제 원인(쿼터 초과인지, 잘못된 요청인지)을 확인하는 진단 스크립트.

사용법 (서버에서):
    cd /home/ubuntu/TicketDiary/backend
    venv/bin/python3 scripts/debug_kopis_detail.py PF295666
"""

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

import httpx  # noqa: E402

from app.core.config import settings  # noqa: E402


async def main(kopis_id: str) -> None:
    async with httpx.AsyncClient(timeout=10.0) as client:
        response = await client.get(
            f"{settings.KOPIS_BASE_URL}/pblprfr/{kopis_id}",
            params={"service": settings.KOPIS_API_KEY},
        )
    print(f"status_code: {response.status_code}")
    print("body:")
    print(response.text)


if __name__ == "__main__":
    kopis_id = sys.argv[1] if len(sys.argv) > 1 else "PF295666"
    asyncio.run(main(kopis_id))
