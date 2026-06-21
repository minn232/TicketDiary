"""add news_feeds.created_at and notification ticket_id cascade

Revision ID: e5f6a7b8c9d0
Revises: d4e5f6a7b8c9
Create Date: 2026-06-08 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op

revision: str = 'e5f6a7b8c9d0'
down_revision: Union[str, None] = 'd4e5f6a7b8c9'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute(
        "ALTER TABLE news_feeds ADD COLUMN IF NOT EXISTS created_at "
        "TIMESTAMPTZ NOT NULL DEFAULT now()"
    )
    op.execute(
        "ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_ticket_id_fkey"
    )
    op.execute(
        "ALTER TABLE notifications ADD CONSTRAINT notifications_ticket_id_fkey "
        "FOREIGN KEY (ticket_id) REFERENCES tickets(id) ON DELETE CASCADE"
    )


def downgrade() -> None:
    op.execute(
        "ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_ticket_id_fkey"
    )
    op.execute(
        "ALTER TABLE notifications ADD CONSTRAINT notifications_ticket_id_fkey "
        "FOREIGN KEY (ticket_id) REFERENCES tickets(id)"
    )
    op.execute("ALTER TABLE news_feeds DROP COLUMN IF EXISTS created_at")
