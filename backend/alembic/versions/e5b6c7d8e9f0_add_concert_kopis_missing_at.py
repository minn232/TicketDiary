"""add concerts.kopis_missing_at

Revision ID: e5b6c7d8e9f0
Revises: d4a5b6c7d8e9
Create Date: 2026-10-05 00:00:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'e5b6c7d8e9f0'
down_revision: Union[str, None] = 'd4a5b6c7d8e9'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


# KOPIS 상세 조회가 NODATA를 준 시점 저장용 - NULL 허용 컬럼 추가라 기존 동작에 영향 없음
def upgrade() -> None:
    op.add_column("concerts", sa.Column("kopis_missing_at", sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column("concerts", "kopis_missing_at")
