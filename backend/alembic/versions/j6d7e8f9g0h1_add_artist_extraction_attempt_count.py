"""add artist_extraction_attempt_count to concerts

Revision ID: j6d7e8f9g0h1
Revises: i5c6d7e8f9g0
Create Date: 2026-08-23 00:30:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'j6d7e8f9g0h1'
down_revision: Union[str, None] = 'i5c6d7e8f9g0'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        'concerts',
        sa.Column('artist_extraction_attempt_count', sa.Integer(), nullable=False, server_default='0'),
    )


def downgrade() -> None:
    op.drop_column('concerts', 'artist_extraction_attempt_count')
