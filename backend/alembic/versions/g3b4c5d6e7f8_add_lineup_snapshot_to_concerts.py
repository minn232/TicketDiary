"""add lineup snapshot fields to concerts

Revision ID: g3b4c5d6e7f8
Revises: f2a3b4c5d6e7
Create Date: 2026-07-29 00:00:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import ARRAY

revision: str = 'g3b4c5d6e7f8'
down_revision: Union[str, None] = 'f2a3b4c5d6e7'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('concerts', sa.Column('lineup_snapshot_hash', sa.String(), nullable=True))
    op.add_column('concerts', sa.Column('lineup_snapshot_img_srcs', ARRAY(sa.String()), nullable=True))
    op.add_column('concerts', sa.Column('lineup_check_attempted_at', sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column('concerts', 'lineup_check_attempted_at')
    op.drop_column('concerts', 'lineup_snapshot_img_srcs')
    op.drop_column('concerts', 'lineup_snapshot_hash')
