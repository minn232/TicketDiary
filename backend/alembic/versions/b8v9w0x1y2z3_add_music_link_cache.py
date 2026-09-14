"""add music_link_cache table

Revision ID: b8v9w0x1y2z3
Revises: u7o8p9q0r1s2
Create Date: 2026-09-14 00:00:00.000001

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = 'b8v9w0x1y2z3'
down_revision: Union[str, None] = 'u7o8p9q0r1s2'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 셋리스트 곡 원탭 연결(music_resolve.py) 결과 캐시 - 유튜브 쿼터 소진 방지용
    # (music_link_cache.py 모델 참고)
    op.create_table(
        'music_link_cache',
        sa.Column('id', postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column('service', sa.String(), nullable=False),
        sa.Column('artist', sa.String(), nullable=False),
        sa.Column('song', sa.String(), nullable=False),
        sa.Column('resolved_url', sa.String(), nullable=True),
        sa.Column('resolved_at', sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('service', 'artist', 'song', name='uq_music_link_cache_service_artist_song'),
    )


def downgrade() -> None:
    op.drop_table('music_link_cache')
