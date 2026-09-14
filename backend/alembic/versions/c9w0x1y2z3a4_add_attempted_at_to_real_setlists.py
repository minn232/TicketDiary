"""add attempted_at to real_setlists

Revision ID: c9w0x1y2z3a4
Revises: b8v9w0x1y2z3
Create Date: 2026-09-14 00:00:00.000001

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'c9w0x1y2z3a4'
down_revision: Union[str, None] = 'b8v9w0x1y2z3'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 조회 시점 실제 셋리스트 확인(check_real_setlist_on_view)의 하루 쿨다운 추적용
    op.add_column('real_setlists', sa.Column('attempted_at', sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column('real_setlists', 'attempted_at')
