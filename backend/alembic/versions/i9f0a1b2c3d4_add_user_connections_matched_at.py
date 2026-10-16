"""add user_connections.matched_at

Revision ID: i9f0a1b2c3d4
Revises: h8e9f0a1b2c3
Create Date: 2026-10-15 15:00:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'i9f0a1b2c3d4'
down_revision: Union[str, None] = 'h8e9f0a1b2c3'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 판정이 짝지어진 시각 - 두 폰 맞대기 애니메이션 시작 시각을 맞추는 기준
    op.add_column('user_connections', sa.Column('matched_at', sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column('user_connections', 'matched_at')
