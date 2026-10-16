"""add nearby_codes.session_started_at

Revision ID: g7d8e9f0a1b2
Revises: f6c7d8e9f0a1
Create Date: 2026-10-13 17:20:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'g7d8e9f0a1b2'
down_revision: Union[str, None] = 'f6c7d8e9f0a1'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 맞대기 화면을 연 시각 - 짝짓기를 이번 시도에 올린 판정으로만 제한(이전 시도 판정과 짝지어지지 않게)
    op.add_column('nearby_codes', sa.Column('session_started_at', sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column('nearby_codes', 'session_started_at')
