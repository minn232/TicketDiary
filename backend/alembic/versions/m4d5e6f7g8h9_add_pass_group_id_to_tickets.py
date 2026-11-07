"""add pass_group_id to tickets

Revision ID: m4d5e6f7g8h9
Revises: l2c3d4e5f6g7
Create Date: 2026-11-07 00:00:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = 'm4d5e6f7g8h9'
down_revision: Union[str, None] = 'l2c3d4e5f6g7'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 2일권/3일권으로 등록한 날짜별 티켓 묶음(값은 첫날 티켓 id)
    op.add_column('tickets', sa.Column('pass_group_id', postgresql.UUID(as_uuid=True), nullable=True))
    op.create_index('ix_tickets_pass_group_id', 'tickets', ['pass_group_id'])


def downgrade() -> None:
    op.drop_index('ix_tickets_pass_group_id', table_name='tickets')
    op.drop_column('tickets', 'pass_group_id')
