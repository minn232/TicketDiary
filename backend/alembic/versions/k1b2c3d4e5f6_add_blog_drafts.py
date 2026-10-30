"""add blog_drafts

Revision ID: k1b2c3d4e5f6
Revises: j0a1b2c3d4e5
Create Date: 2026-10-28 00:00:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = 'k1b2c3d4e5f6'
down_revision: Union[str, None] = 'j0a1b2c3d4e5'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 티켓별 블로그 글 초안 - 요청은 저장해두고 밤 LLM 배치가 생성
    op.create_table(
        'blog_drafts',
        sa.Column('id', postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column('ticket_id', postgresql.UUID(as_uuid=True), sa.ForeignKey('tickets.id', ondelete='CASCADE'), nullable=False, unique=True),
        sa.Column('emotion', sa.Text(), nullable=False),
        sa.Column('title', sa.String(), nullable=True),
        sa.Column('body', sa.Text(), nullable=True),
        sa.Column('requested_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('generated_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('attempt_count', sa.Integer(), nullable=False, server_default=sa.text('0')),
        sa.Column('last_error', sa.String(), nullable=True),
    )


def downgrade() -> None:
    op.drop_table('blog_drafts')
