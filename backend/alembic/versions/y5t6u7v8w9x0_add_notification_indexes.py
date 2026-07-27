"""add notification indexes

Revision ID: y5t6u7v8w9x0
Revises: x4s5t6u7v8w9
Create Date: 2026-07-23 00:00:00.000002

"""
from typing import Sequence, Union

from alembic import op

revision: str = 'y5t6u7v8w9x0'
down_revision: Union[str, None] = 'x4s5t6u7v8w9'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_index(
        "ix_notifications_is_sent_scheduled_at",
        "notifications",
        ["is_sent", "scheduled_at"],
    )
    op.create_index(
        "ix_notifications_ticket_id_type",
        "notifications",
        ["ticket_id", "type"],
    )
    op.create_index(
        "ix_notifications_concert_id_type",
        "notifications",
        ["concert_id", "type"],
    )


def downgrade() -> None:
    op.drop_index("ix_notifications_concert_id_type", table_name="notifications")
    op.drop_index("ix_notifications_ticket_id_type", table_name="notifications")
    op.drop_index("ix_notifications_is_sent_scheduled_at", table_name="notifications")
