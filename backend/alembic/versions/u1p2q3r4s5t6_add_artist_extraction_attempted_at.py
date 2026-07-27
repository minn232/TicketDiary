"""add artist_extraction_attempted_at to concerts

Revision ID: u1p2q3r4s5t6
Revises: t0o1p2q3r4s5
Create Date: 2026-07-22 00:00:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'u1p2q3r4s5t6'
down_revision: Union[str, None] = 't0o1p2q3r4s5'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('concerts', sa.Column('artist_extraction_attempted_at', sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column('concerts', 'artist_extraction_attempted_at')
