"""add admin_edited to timetables

Revision ID: o6f7g8h9i0j1
Revises: n5e6f7g8h9i0
Create Date: 2026-11-11 00:00:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'o6f7g8h9i0j1'
down_revision: Union[str, None] = 'n5e6f7g8h9i0'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 관리자가 직접 만들거나 고친 시간표 표시 - true면 LLM 크롤링 콜백이 덮어쓰지 않음
    op.add_column('timetables', sa.Column('admin_edited', sa.Boolean(), server_default=sa.text('false'), nullable=False))


def downgrade() -> None:
    op.drop_column('timetables', 'admin_edited')
