"""add diary_requested_at to tickets

Revision ID: a7v8w9x0y1z2
Revises: z6u7v8w9x0y1
Create Date: 2026-07-23 00:00:00.000004

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'a7v8w9x0y1z2'
down_revision: Union[str, None] = 'z6u7v8w9x0y1'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('tickets', sa.Column('diary_requested_at', sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column('tickets', 'diary_requested_at')
