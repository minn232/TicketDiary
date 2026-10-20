"""allow multiple tickets per concert on different attended dates

Revision ID: j0a1b2c3d4e5
Revises: i9f0a1b2c3d4
Create Date: 2026-10-21 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op

revision: str = 'j0a1b2c3d4e5'
down_revision: Union[str, None] = 'i9f0a1b2c3d4'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


# 여러 날 하는 공연(KOPIS 공연 1개)을 관람일별로 각각 등록할 수 있도록 유니크 키에 관람일 추가
def upgrade() -> None:
    op.drop_constraint("uq_tickets_user_concert", "tickets", type_="unique")
    op.create_unique_constraint(
        "uq_tickets_user_concert_date", "tickets", ["user_id", "concert_id", "attended_date"]
    )


# 같은 공연에 티켓이 2장 이상인 유저가 있으면 실패함 - 그 경우 중복 티켓을 먼저 정리해야 함
def downgrade() -> None:
    op.drop_constraint("uq_tickets_user_concert_date", "tickets", type_="unique")
    op.create_unique_constraint("uq_tickets_user_concert", "tickets", ["user_id", "concert_id"])
