"""add ai_reviewed_at to concerts

Revision ID: u7o8p9q0r1s2
Revises: t6n7o8p9q0r1
Create Date: 2026-09-11 00:00:00.000001

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'u7o8p9q0r1s2'
down_revision: Union[str, None] = 't6n7o8p9q0r1'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Claude가 대신 검수한 시각(사람 검수 admin_reviewed_at과 구분) - admin.html에 별도 표시용
    op.add_column(
        'concerts',
        sa.Column('ai_reviewed_at', sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column('concerts', 'ai_reviewed_at')
