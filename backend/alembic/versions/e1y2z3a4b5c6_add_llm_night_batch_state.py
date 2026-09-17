"""add llm_night_batch_state table

Revision ID: e1y2z3a4b5c6
Revises: d0x1y2z3a4b5
Create Date: 2026-09-14 00:00:00.000003

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'e1y2z3a4b5c6'
down_revision: Union[str, None] = 'd0x1y2z3a4b5'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 밤배치 LLM 조기 정지 판단용 싱글턴 상태 테이블 (llm_batch_state.py 모델 참고)
    op.create_table(
        'llm_night_batch_state',
        sa.Column('id', sa.String(), nullable=False),
        sa.Column('last_send_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('last_callback_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('early_stopped_at', sa.DateTime(timezone=True), nullable=True),
        sa.PrimaryKeyConstraint('id'),
    )


def downgrade() -> None:
    op.drop_table('llm_night_batch_state')
