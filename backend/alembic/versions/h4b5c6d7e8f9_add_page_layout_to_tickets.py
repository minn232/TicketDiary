"""add page_layout to tickets

Revision ID: h4b5c6d7e8f9
Revises: g3a4b5c6d7e8
Create Date: 2026-09-23 00:00:00.000001

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = 'h4b5c6d7e8f9'
down_revision: Union[str, None] = 'g3a4b5c6d7e8'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 공연후 페이지 배치(포스터/사진/자유메모 위치) - 기기 로컬 저장에서 서버 저장으로 옮김
    op.add_column(
        'tickets',
        sa.Column('page_layout', postgresql.JSONB(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column('tickets', 'page_layout')
