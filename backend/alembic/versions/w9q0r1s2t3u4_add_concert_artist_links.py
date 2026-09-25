"""add concert_artist_links and artist_identity_changes

Revision ID: w9q0r1s2t3u4
Revises: v8p9q0r1s2t3
Create Date: 2026-09-25 00:00:00.000002

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = 'w9q0r1s2t3u4'
down_revision: Union[str, None] = 'v8p9q0r1s2t3'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 공연별 아티스트 연결(전역 별칭보다 우선) - 유저/관리자가 "이 공연의 ○○는 이 사람"으로 고친 값
    op.create_table(
        'concert_artist_links',
        sa.Column('id', postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column('concert_id', postgresql.UUID(as_uuid=True), sa.ForeignKey('concerts.id', ondelete='CASCADE'), nullable=False),
        sa.Column('artist_text', sa.String(), nullable=False),
        sa.Column('canonical_id', postgresql.UUID(as_uuid=True), sa.ForeignKey('canonical_artists.id', ondelete='CASCADE'), nullable=True),
        sa.Column('updated_at', sa.DateTime(timezone=True), nullable=True),
        sa.UniqueConstraint('concert_id', 'artist_text', name='uq_concert_artist_link'),
    )
    # 연결 변경 기록 - 관리자가 보고 되돌릴 수 있게
    op.create_table(
        'artist_identity_changes',
        sa.Column('id', postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column('concert_id', postgresql.UUID(as_uuid=True), sa.ForeignKey('concerts.id', ondelete='CASCADE'), nullable=False),
        sa.Column('artist_text', sa.String(), nullable=False),
        sa.Column('before_canonical_id', postgresql.UUID(as_uuid=True), sa.ForeignKey('canonical_artists.id', ondelete='SET NULL'), nullable=True),
        sa.Column('before_was_link', sa.Boolean(), nullable=False, server_default=sa.text('false')),
        sa.Column('after_canonical_id', postgresql.UUID(as_uuid=True), sa.ForeignKey('canonical_artists.id', ondelete='SET NULL'), nullable=True),
        sa.Column('changed_by_user_id', postgresql.UUID(as_uuid=True), sa.ForeignKey('users.id', ondelete='SET NULL'), nullable=True),
        sa.Column('source', sa.String(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('reverted_at', sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_table('artist_identity_changes')
    op.drop_table('concert_artist_links')
