"""add musicbrainz artist normalization tables

Revision ID: 1318c8becb68
Revises: k7e8f9g0h1i2
Create Date: 2026-08-31 21:33:47.373157

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = '1318c8becb68'
down_revision: Union[str, None] = 'k7e8f9g0h1i2'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table('canonical_artists',
    sa.Column('id', sa.UUID(), nullable=False),
    sa.Column('mbid', sa.String(), nullable=True),
    sa.Column('canonical_name', sa.String(), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), nullable=True),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index(op.f('ix_canonical_artists_mbid'), 'canonical_artists', ['mbid'], unique=True)
    op.create_table('artist_aliases',
    sa.Column('id', sa.UUID(), nullable=False),
    sa.Column('canonical_artist_id', sa.UUID(), nullable=False),
    sa.Column('alias_text', sa.String(), nullable=False),
    sa.Column('source', sa.String(), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), nullable=True),
    sa.ForeignKeyConstraint(['canonical_artist_id'], ['canonical_artists.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index(op.f('ix_artist_aliases_alias_text'), 'artist_aliases', ['alias_text'], unique=False)
    op.create_table('artist_normalization_status',
    sa.Column('id', sa.UUID(), nullable=False),
    sa.Column('concert_id', sa.UUID(), nullable=False),
    sa.Column('artist_text', sa.String(), nullable=False),
    sa.Column('status', sa.String(), nullable=False),
    sa.Column('attempt_count', sa.Integer(), nullable=False),
    sa.Column('last_attempted_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('created_at', sa.DateTime(timezone=True), nullable=True),
    sa.ForeignKeyConstraint(['concert_id'], ['concerts.id'], ),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('concert_id', 'artist_text', name='uq_artist_normalization_status_concert_artist')
    )
    op.create_index(op.f('ix_artist_normalization_status_status'), 'artist_normalization_status', ['status'], unique=False)


def downgrade() -> None:
    op.drop_index(op.f('ix_artist_normalization_status_status'), table_name='artist_normalization_status')
    op.drop_table('artist_normalization_status')
    op.drop_index(op.f('ix_artist_aliases_alias_text'), table_name='artist_aliases')
    op.drop_table('artist_aliases')
    op.drop_index(op.f('ix_canonical_artists_mbid'), table_name='canonical_artists')
    op.drop_table('canonical_artists')
