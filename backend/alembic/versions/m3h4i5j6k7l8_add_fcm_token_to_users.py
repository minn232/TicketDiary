"""add missing fcm_token column to users

Revision ID: m3h4i5j6k7l8
Revises: l2g3h4i5j6k7
Create Date: 2026-07-09 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = 'm3h4i5j6k7l8'
down_revision: Union[str, None] = 'l2g3h4i5j6k7'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('users', sa.Column('fcm_token', sa.String(), nullable=True))


def downgrade() -> None:
    op.drop_column('users', 'fcm_token')
