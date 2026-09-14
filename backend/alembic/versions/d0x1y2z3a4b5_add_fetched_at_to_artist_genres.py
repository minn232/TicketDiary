"""add fetched_at to artist_genres

Revision ID: d0x1y2z3a4b5
Revises: c9w0x1y2z3a4
Create Date: 2026-09-14 00:00:00.000002

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'd0x1y2z3a4b5'
down_revision: Union[str, None] = 'c9w0x1y2z3a4'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Last.fm 장르 캐시 주기적 재조회(TTL) 도입용 - artist_similarities.fetched_at과 동일 용도.
    # server_default로 기존 행도 채워서 마이그레이션 순간 전부 "방금 갱신"으로 잡혀 재조회 폭주 방지
    op.add_column(
        'artist_genres',
        sa.Column('fetched_at', sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )


def downgrade() -> None:
    op.drop_column('artist_genres', 'fetched_at')
