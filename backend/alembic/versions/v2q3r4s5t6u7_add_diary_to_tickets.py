"""add diary to tickets

Revision ID: v2q3r4s5t6u7
Revises: u1p2q3r4s5t6
Create Date: 2026-07-22 00:00:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'v2q3r4s5t6u7'
down_revision: Union[str, None] = 'u1p2q3r4s5t6'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('tickets', sa.Column('diary', sa.Text(), nullable=True))


def downgrade() -> None:
    op.drop_column('tickets', 'diary')
