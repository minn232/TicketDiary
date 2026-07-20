"""add delivery_date to concerts

Revision ID: r8m9n0o1p2q3
Revises: q7l8m9n0o1p2
Create Date: 2026-07-20 00:00:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'r8m9n0o1p2q3'
down_revision: Union[str, None] = 'q7l8m9n0o1p2'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('concerts', sa.Column('delivery_date', sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column('concerts', 'delivery_date')
