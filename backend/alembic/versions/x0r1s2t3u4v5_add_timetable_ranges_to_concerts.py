"""add concerts.timetable_ranges

Revision ID: x0r1s2t3u4v5
Revises: w9q0r1s2t3u4
Create Date: 2026-09-27 00:00:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB

revision: str = 'x0r1s2t3u4v5'
down_revision: Union[str, None] = 'w9q0r1s2t3u4'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('concerts', sa.Column('timetable_ranges', JSONB(), nullable=True))


def downgrade() -> None:
    op.drop_column('concerts', 'timetable_ranges')
