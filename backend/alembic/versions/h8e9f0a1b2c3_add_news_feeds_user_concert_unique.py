"""add unique (user_id, concert_id) to news_feeds

Revision ID: h8e9f0a1b2c3
Revises: g7d8e9f0a1b2
Create Date: 2026-10-13 22:00:00.000000

"""
from typing import Sequence, Union

from alembic import op

revision: str = 'h8e9f0a1b2c3'
down_revision: Union[str, None] = 'g7d8e9f0a1b2'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 야간 배치와 팔로우 즉시 생성이 겹치면 같은 소식이 두 번 생길 수 있어 막음 - 이미 있는 중복은
    # 먼저 생긴 것만 남김
    op.execute(
        """
        DELETE FROM news_feeds a
        USING news_feeds b
        WHERE a.user_id = b.user_id AND a.concert_id = b.concert_id
          AND (a.created_at, a.id::text) > (b.created_at, b.id::text)
        """
    )
    op.create_unique_constraint('uq_news_feeds_user_concert', 'news_feeds', ['user_id', 'concert_id'])


def downgrade() -> None:
    op.drop_constraint('uq_news_feeds_user_concert', 'news_feeds', type_='unique')
