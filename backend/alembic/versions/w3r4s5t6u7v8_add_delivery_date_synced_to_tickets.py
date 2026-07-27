"""add delivery_date_synced to tickets

Revision ID: w3r4s5t6u7v8
Revises: v2q3r4s5t6u7
Create Date: 2026-07-23 00:00:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'w3r4s5t6u7v8'
down_revision: Union[str, None] = 'v2q3r4s5t6u7'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('tickets', sa.Column('delivery_date_synced', sa.Boolean(), nullable=True))


def downgrade() -> None:
    op.drop_column('tickets', 'delivery_date_synced')
