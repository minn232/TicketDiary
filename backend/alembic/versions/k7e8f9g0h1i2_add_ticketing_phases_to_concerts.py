"""add concerts.ticketing_phases

Revision ID: k7e8f9g0h1i2
Revises: j6d7e8f9g0h1
Create Date: 2026-08-27 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB

revision: str = 'k7e8f9g0h1i2'
down_revision: Union[str, None] = 'j6d7e8f9g0h1'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('concerts', sa.Column('ticketing_phases', JSONB(), nullable=True))


def downgrade() -> None:
    op.drop_column('concerts', 'ticketing_phases')
