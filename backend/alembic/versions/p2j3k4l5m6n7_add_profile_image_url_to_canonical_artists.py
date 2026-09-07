"""add profile_image_url to canonical_artists

Revision ID: p2j3k4l5m6n7
Revises: o1i2j3k4l5m6
Create Date: 2026-09-07 00:00:00.000001

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'p2j3k4l5m6n7'
down_revision: Union[str, None] = 'o1i2j3k4l5m6'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Spotify(mbid로 연결된 공식 링크) 우선, 없으면 Wikidata 대표 이미지로 대체 - 둘 다 없으면
    # NULL(화면에서 플레이스홀더 아이콘)
    op.add_column(
        'canonical_artists',
        sa.Column('profile_image_url', sa.String(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column('canonical_artists', 'profile_image_url')
