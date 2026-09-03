"""add display_name to canonical_artists

Revision ID: o1i2j3k4l5m6
Revises: n0h1i2j3k4l5
Create Date: 2026-09-03 00:00:00.000001

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'o1i2j3k4l5m6'
down_revision: Union[str, None] = 'n0h1i2j3k4l5'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # canonical_name은 매칭 키로 계속 쓰고(MusicBrainz 원문), 화면 표시만 다르게 하고 싶을 때
    # (Wikidata 한글 label 자동 채택, admin 수동 선택) 이 컬럼을 대신 씀 - NULL이면 canonical_name
    # 그대로 표시(기존 동작과 동일)
    op.add_column(
        'canonical_artists',
        sa.Column('display_name', sa.String(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column('canonical_artists', 'display_name')
