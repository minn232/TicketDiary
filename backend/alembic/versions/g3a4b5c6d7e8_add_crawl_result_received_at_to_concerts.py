"""add crawl_result_received_at to concerts

Revision ID: g3a4b5c6d7e8
Revises: f2z3a4b5c6d7
Create Date: 2026-09-16 00:00:00.000001

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'g3a4b5c6d7e8'
down_revision: Union[str, None] = 'f2z3a4b5c6d7'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # LLM 크롤링 분석 콜백이 도착한 시각 - ticketing_date 유무와 무관하게 "처리는 됐다"를 표시
    op.add_column(
        'concerts',
        sa.Column('crawl_result_received_at', sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column('concerts', 'crawl_result_received_at')
