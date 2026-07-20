"""add crawl_attempted_at to concerts

Revision ID: s9n0o1p2q3r4
Revises: r8m9n0o1p2q3
Create Date: 2026-07-20 00:00:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 's9n0o1p2q3r4'
down_revision: Union[str, None] = 'r8m9n0o1p2q3'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('concerts', sa.Column('crawl_attempted_at', sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column('concerts', 'crawl_attempted_at')
