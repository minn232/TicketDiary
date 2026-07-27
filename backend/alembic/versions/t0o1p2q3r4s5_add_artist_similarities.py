"""add artist_similarities table

Revision ID: t0o1p2q3r4s5
Revises: s9n0o1p2q3r4
Create Date: 2026-07-22 00:00:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = 't0o1p2q3r4s5'
down_revision: Union[str, None] = 's9n0o1p2q3r4'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'artist_similarities',
        sa.Column('id', UUID(as_uuid=True), primary_key=True),
        sa.Column('artist_name', sa.String(), nullable=False),
        sa.Column('similar_artist_name', sa.String(), nullable=False),
        sa.Column('match_score', sa.Float(), nullable=False),
        sa.Column('fetched_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    )
    op.create_index('ix_artist_similarities_artist_name', 'artist_similarities', ['artist_name'])


def downgrade() -> None:
    op.drop_index('ix_artist_similarities_artist_name', table_name='artist_similarities')
    op.drop_table('artist_similarities')
