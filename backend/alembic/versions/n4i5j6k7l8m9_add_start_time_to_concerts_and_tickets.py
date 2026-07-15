"""add start_time to concerts and tickets

Revision ID: n4i5j6k7l8m9
Revises: m3h4i5j6k7l8
Create Date: 2026-07-13 00:00:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'n4i5j6k7l8m9'
down_revision: Union[str, None] = 'm3h4i5j6k7l8'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('concerts', sa.Column('start_time', sa.String(), nullable=True))
    op.add_column('tickets', sa.Column('start_time', sa.String(), nullable=True))


def downgrade() -> None:
    op.drop_column('tickets', 'start_time')
    op.drop_column('concerts', 'start_time')
