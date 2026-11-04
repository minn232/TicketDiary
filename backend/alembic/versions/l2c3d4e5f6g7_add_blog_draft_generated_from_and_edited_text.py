"""add generated_from/edited_text to blog_drafts, blog_draft notification type and setting

Revision ID: l2c3d4e5f6g7
Revises: k1b2c3d4e5f6
Create Date: 2026-11-04 00:00:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'l2c3d4e5f6g7'
down_revision: Union[str, None] = 'k1b2c3d4e5f6'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 정리본을 만든 메모 원문 - 메모를 고쳐도 정리본을 남겨두고, 원문과 달라졌는지로 다시 정리할지 판단
    op.add_column('blog_drafts', sa.Column('generated_from', sa.Text(), nullable=True))
    # 앱에서 고친 정리본(제목+본문 합친 글) - 새 정리본이 나오면 지움
    op.add_column('blog_drafts', sa.Column('edited_text', sa.Text(), nullable=True))
    op.execute(
        "UPDATE blog_drafts SET generated_from = emotion "
        "WHERE body IS NOT NULL AND generated_at IS NOT NULL AND generated_at >= requested_at"
    )
    op.execute("ALTER TYPE notificationtype ADD VALUE IF NOT EXISTS 'blog_draft'")
    # 기존 유저 설정엔 키가 없어도 켜짐으로 읽힘(.get 기본값 True)이라 기본값만 바꿈
    op.execute(
        "ALTER TABLE users ALTER COLUMN notification_settings "
        "SET DEFAULT '{\"delivery\": true, \"day_before\": true, \"concert_day\": true, "
        "\"ticketing\": true, \"new_concert\": true, \"blog_draft\": true}'::jsonb"
    )


def downgrade() -> None:
    # enum 값은 Postgres에서 따로 뺄 수 없어 남겨둠
    op.execute(
        "ALTER TABLE users ALTER COLUMN notification_settings "
        "SET DEFAULT '{\"delivery\": true, \"day_before\": true, \"concert_day\": true, "
        "\"ticketing\": true, \"new_concert\": true}'::jsonb"
    )
    op.drop_column('blog_drafts', 'edited_text')
    op.drop_column('blog_drafts', 'generated_from')
