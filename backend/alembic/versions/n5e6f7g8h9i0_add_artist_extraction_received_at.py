"""add artist_extraction_received_at to concerts

Revision ID: n5e6f7g8h9i0
Revises: m4d5e6f7g8h9
Create Date: 2026-11-08 00:00:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'n5e6f7g8h9i0'
down_revision: Union[str, None] = 'm4d5e6f7g8h9'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 포스터 아티스트 추출 콜백을 받은 시점 - 있으면 재전송 안 함(전엔 성공한 것도 5회까지 다시 보냄)
    op.add_column('concerts', sa.Column('artist_extraction_received_at', sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column('concerts', 'artist_extraction_received_at')
