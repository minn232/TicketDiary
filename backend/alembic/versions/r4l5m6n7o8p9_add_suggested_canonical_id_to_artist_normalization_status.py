"""add suggested_canonical_id to artist_normalization_status

Revision ID: r4l5m6n7o8p9
Revises: q3k4l5m6n7o8
Create Date: 2026-09-11 00:00:00.000001

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = 'r4l5m6n7o8p9'
down_revision: Union[str, None] = 'q3k4l5m6n7o8'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # mbid 없는(admin 수동 생성) 별칭과 문자열만 일치해 자동병합 대신 admin 확인을 기다리는
    # "suggested" 상태에서 어느 canonical을 제안 중인지 저장(동명이인 오병합 방지, 별첨 참고)
    op.add_column(
        'artist_normalization_status',
        sa.Column('suggested_canonical_id', postgresql.UUID(as_uuid=True), nullable=True),
    )
    op.create_foreign_key(
        'fk_artist_normalization_status_suggested_canonical_id',
        'artist_normalization_status',
        'canonical_artists',
        ['suggested_canonical_id'],
        ['id'],
    )


def downgrade() -> None:
    op.drop_constraint(
        'fk_artist_normalization_status_suggested_canonical_id',
        'artist_normalization_status',
        type_='foreignkey',
    )
    op.drop_column('artist_normalization_status', 'suggested_canonical_id')
