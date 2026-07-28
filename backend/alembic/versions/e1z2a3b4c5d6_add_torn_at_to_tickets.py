"""add torn_at to tickets

Revision ID: e1z2a3b4c5d6
Revises: d0y1z2a3b4c5
Create Date: 2026-07-28 00:20:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'e1z2a3b4c5d6'
down_revision: Union[str, None] = 'd0y1z2a3b4c5'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('tickets', sa.Column('torn_at', sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column('tickets', 'torn_at')
