"""add concert_lineups table

Revision ID: i5c6d7e8f9g0
Revises: h4c5d6e7f8g9
Create Date: 2026-08-23 00:00:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = 'i5c6d7e8f9g0'
down_revision: Union[str, None] = 'h4c5d6e7f8g9'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'concert_lineups',
        sa.Column('id', UUID(as_uuid=True), primary_key=True),
        sa.Column('concert_id', UUID(as_uuid=True), sa.ForeignKey('concerts.id'), nullable=False),
        sa.Column('artist', sa.String(), nullable=False),
        sa.Column('performance_date', sa.Date(), nullable=False),
        sa.Column('source', sa.String(), nullable=False),
    )
    op.create_unique_constraint(
        'uq_concert_lineup_artist_date', 'concert_lineups', ['concert_id', 'artist', 'performance_date']
    )
    op.create_index('ix_concert_lineups_concert_id', 'concert_lineups', ['concert_id'])


def downgrade() -> None:
    op.drop_index('ix_concert_lineups_concert_id', table_name='concert_lineups')
    op.drop_constraint('uq_concert_lineup_artist_date', 'concert_lineups', type_='unique')
    op.drop_table('concert_lineups')
