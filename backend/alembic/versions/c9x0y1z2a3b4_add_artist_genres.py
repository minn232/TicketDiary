"""add artist_genres table

Revision ID: c9x0y1z2a3b4
Revises: b8w9x0y1z2a3
Create Date: 2026-07-27 00:00:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID, ARRAY

revision: str = 'c9x0y1z2a3b4'
down_revision: Union[str, None] = 'b8w9x0y1z2a3'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'artist_genres',
        sa.Column('id', UUID(as_uuid=True), primary_key=True),
        sa.Column('artist_name', sa.String(), nullable=False),
        sa.Column('genres', ARRAY(sa.String()), nullable=True),
        sa.UniqueConstraint('artist_name', name='uq_artist_genres_artist_name'),
    )
    op.create_index('ix_artist_genres_artist_name', 'artist_genres', ['artist_name'])


def downgrade() -> None:
    op.drop_index('ix_artist_genres_artist_name', table_name='artist_genres')
    op.drop_table('artist_genres')
