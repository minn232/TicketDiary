"""add food_allowed to concerts

Revision ID: h4c5d6e7f8g9
Revises: g3b4c5d6e7f8
Create Date: 2026-08-06 00:00:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'h4c5d6e7f8g9'
down_revision: Union[str, None] = 'g3b4c5d6e7f8'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('concerts', sa.Column('food_allowed', sa.String(), nullable=True))


def downgrade() -> None:
    op.drop_column('concerts', 'food_allowed')
