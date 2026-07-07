"""add ondelete CASCADE to news_feeds.user_id and notifications.user_id

Revision ID: i9d0e1f2g3h4
Revises: h8c9d0e1f2g3
Create Date: 2026-06-30 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op

revision: str = 'i9d0e1f2g3h4'
down_revision: Union[str, None] = 'h8c9d0e1f2g3'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute(
        "ALTER TABLE news_feeds DROP CONSTRAINT IF EXISTS news_feeds_user_id_fkey"
    )
    op.execute(
        "ALTER TABLE news_feeds ADD CONSTRAINT news_feeds_user_id_fkey "
        "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE"
    )

    op.execute(
        "ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_user_id_fkey"
    )
    op.execute(
        "ALTER TABLE notifications ADD CONSTRAINT notifications_user_id_fkey "
        "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE"
    )


def downgrade() -> None:
    op.execute(
        "ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_user_id_fkey"
    )
    op.execute(
        "ALTER TABLE notifications ADD CONSTRAINT notifications_user_id_fkey "
        "FOREIGN KEY (user_id) REFERENCES users(id)"
    )

    op.execute(
        "ALTER TABLE news_feeds DROP CONSTRAINT IF EXISTS news_feeds_user_id_fkey"
    )
    op.execute(
        "ALTER TABLE news_feeds ADD CONSTRAINT news_feeds_user_id_fkey "
        "FOREIGN KEY (user_id) REFERENCES users(id)"
    )
