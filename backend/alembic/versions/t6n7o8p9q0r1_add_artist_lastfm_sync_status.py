"""add artist_lastfm_sync_status table

Revision ID: t6n7o8p9q0r1
Revises: s5m6n7o8p9q0
Create Date: 2026-09-11 00:00:00.000001

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = 't6n7o8p9q0r1'
down_revision: Union[str, None] = 's5m6n7o8p9q0'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Last.fm이 결과를 못 준 아티스트의 재시도 기록 - 쿨다운+상한 재시도용
    # (lastfm.py의 _filter_lastfm_retry_eligible 참고)
    op.create_table(
        'artist_lastfm_sync_status',
        sa.Column('id', postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column('artist_name', sa.String(), nullable=False),
        sa.Column('sync_type', sa.String(), nullable=False),
        sa.Column('last_attempted_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('attempt_count', sa.Integer(), nullable=False),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('artist_name', 'sync_type', name='uq_artist_lastfm_sync_status_name_type'),
    )
    op.create_index(
        op.f('ix_artist_lastfm_sync_status_artist_name'),
        'artist_lastfm_sync_status',
        ['artist_name'],
    )


def downgrade() -> None:
    op.drop_index(op.f('ix_artist_lastfm_sync_status_artist_name'), table_name='artist_lastfm_sync_status')
    op.drop_table('artist_lastfm_sync_status')
