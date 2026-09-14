"""add pending_count/all_sent_at to llm_night_batch_state

Revision ID: f2z3a4b5c6d7
Revises: e1y2z3a4b5c6
Create Date: 2026-09-14 00:00:00.000004

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'f2z3a4b5c6d7'
down_revision: Union[str, None] = 'e1y2z3a4b5c6'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 정확한 건수 매칭으로 마지막 콜백 도착 즉시 조기 정지하기 위한 컬럼들
    # (llm_batch_state.py 모델 참고, 기존 유휴시간 방식은 안전망으로 유지)
    op.add_column(
        'llm_night_batch_state',
        sa.Column('all_sent_at', sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        'llm_night_batch_state',
        sa.Column('pending_count', sa.Integer(), server_default=sa.text('0'), nullable=False),
    )


def downgrade() -> None:
    op.drop_column('llm_night_batch_state', 'pending_count')
    op.drop_column('llm_night_batch_state', 'all_sent_at')
