"""add venue_layouts table

Revision ID: h8c9d0e1f2g3
Revises: g7b8c9d0e1f2
Create Date: 2026-06-30 00:00:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID, JSONB

revision: str = 'h8c9d0e1f2g3'
down_revision: Union[str, None] = 'g7b8c9d0e1f2'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'venue_layouts',
        sa.Column('id', UUID(as_uuid=True), primary_key=True),
        sa.Column('concert_id', UUID(as_uuid=True), sa.ForeignKey('concerts.id'), nullable=False, unique=True),
        sa.Column('image_url', sa.String(), nullable=True),
        sa.Column('layout_data', JSONB(), nullable=True),
    )


def downgrade() -> None:
    op.drop_table('venue_layouts')
