"""add concerts.runtime_minutes

Revision ID: d4a5b6c7d8e9
Revises: c3z4a5b6c7d8
Create Date: 2026-10-05 00:00:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'd4a5b6c7d8e9'
down_revision: Union[str, None] = 'c3z4a5b6c7d8'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


# KOPIS 상세의 공연 러닝타임(prfruntime)을 분 단위로 저장 - NULL 허용 컬럼 추가라 기존 동작에 영향 없음
def upgrade() -> None:
    op.add_column("concerts", sa.Column("runtime_minutes", sa.Integer(), nullable=True))


def downgrade() -> None:
    op.drop_column("concerts", "runtime_minutes")
