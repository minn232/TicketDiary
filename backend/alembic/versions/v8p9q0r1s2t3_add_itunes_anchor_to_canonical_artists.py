"""add itunes anchor to canonical_artists

Revision ID: v8p9q0r1s2t3
Revises: h4b5c6d7e8f9
Create Date: 2026-09-25 00:00:00.000001

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'v8p9q0r1s2t3'
down_revision: Union[str, None] = 'h4b5c6d7e8f9'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 예상 셋리 대표곡용 iTunes 아티스트 - 유저가 고르거나 MusicBrainz 링크/자동으로 확정한 값
    op.add_column('canonical_artists', sa.Column('itunes_artist_id', sa.String(), nullable=True))
    op.add_column('canonical_artists', sa.Column('anchor_confirmed_by', sa.String(), nullable=True))


def downgrade() -> None:
    op.drop_column('canonical_artists', 'anchor_confirmed_by')
    op.drop_column('canonical_artists', 'itunes_artist_id')
