"""add concerts.visit and canonical_artists musicbrainz genre columns

Revision ID: c3z4a5b6c7d8
Revises: b2y3z4a5c6d7
Create Date: 2026-10-05 00:00:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = 'c3z4a5b6c7d8'
down_revision: Union[str, None] = 'b2y3z4a5c6d7'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


# KOPIS 내한 여부와 MusicBrainz 장르/국가 저장용 - 전부 NULL 허용 컬럼 추가라 기존 동작에 영향 없음
def upgrade() -> None:
    op.add_column("concerts", sa.Column("visit", sa.Boolean(), nullable=True))
    op.add_column("canonical_artists", sa.Column("mb_genres", postgresql.ARRAY(sa.String()), nullable=True))
    op.add_column("canonical_artists", sa.Column("mb_country", sa.String(), nullable=True))
    op.add_column("canonical_artists", sa.Column("mb_genres_fetched_at", sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column("canonical_artists", "mb_genres_fetched_at")
    op.drop_column("canonical_artists", "mb_country")
    op.drop_column("canonical_artists", "mb_genres")
    op.drop_column("concerts", "visit")
