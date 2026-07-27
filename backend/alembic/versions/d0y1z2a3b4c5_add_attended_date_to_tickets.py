"""add attended_date to tickets

Revision ID: d0y1z2a3b4c5
Revises: c9x0y1z2a3b4
Create Date: 2026-07-27 00:10:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'd0y1z2a3b4c5'
down_revision: Union[str, None] = 'c9x0y1z2a3b4'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('tickets', sa.Column('attended_date', sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column('tickets', 'attended_date')
