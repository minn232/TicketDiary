"""add musicbrainz artist normalization tables

Revision ID: l8f9g0h1i2j3
Revises: k7e8f9g0h1i2
Create Date: 2026-08-31 21:33:47.373157

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = 'l8f9g0h1i2j3'
down_revision: Union[str, None] = 'k7e8f9g0h1i2'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'canonical_artists',
        sa.Column('id', UUID(as_uuid=True), primary_key=True),
        sa.Column('mbid', sa.String(), nullable=True, unique=True),
        sa.Column('canonical_name', sa.String(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=True),
    )
    op.create_table(
        'artist_aliases',
        sa.Column('id', UUID(as_uuid=True), primary_key=True),
        sa.Column('canonical_artist_id', UUID(as_uuid=True), sa.ForeignKey('canonical_artists.id'), nullable=False),
        sa.Column('alias_text', sa.String(), nullable=False),
        sa.Column('source', sa.String(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index('ix_artist_aliases_alias_text', 'artist_aliases', ['alias_text'])
    op.create_table(
        'artist_normalization_status',
        sa.Column('id', UUID(as_uuid=True), primary_key=True),
        sa.Column('concert_id', UUID(as_uuid=True), sa.ForeignKey('concerts.id'), nullable=False),
        sa.Column('artist_text', sa.String(), nullable=False),
        sa.Column('status', sa.String(), nullable=False),
        sa.Column('attempt_count', sa.Integer(), nullable=False),
        sa.Column('last_attempted_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=True),
        sa.UniqueConstraint('concert_id', 'artist_text', name='uq_artist_normalization_status_concert_artist'),
    )
    op.create_index('ix_artist_normalization_status_status', 'artist_normalization_status', ['status'])


def downgrade() -> None:
    op.drop_index('ix_artist_normalization_status_status', table_name='artist_normalization_status')
    op.drop_table('artist_normalization_status')
    op.drop_index('ix_artist_aliases_alias_text', table_name='artist_aliases')
    op.drop_table('artist_aliases')
    op.drop_table('canonical_artists')
