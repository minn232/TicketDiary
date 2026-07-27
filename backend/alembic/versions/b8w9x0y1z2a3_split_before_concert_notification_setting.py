"""split before_concert into day_before/concert_day in users.notification_settings default

Revision ID: b8w9x0y1z2a3
Revises: a7v8w9x0y1z2
Create Date: 2026-07-27 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op

revision: str = 'b8w9x0y1z2a3'
down_revision: Union[str, None] = 'a7v8w9x0y1z2'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute(
        "ALTER TABLE users ALTER COLUMN notification_settings "
        "SET DEFAULT '{\"delivery\": true, \"day_before\": true, \"concert_day\": true, "
        "\"ticketing\": true, \"new_concert\": true}'::jsonb"
    )


def downgrade() -> None:
    op.execute(
        "ALTER TABLE users ALTER COLUMN notification_settings "
        "SET DEFAULT '{\"delivery\": true, \"before_concert\": true, \"ticketing\": true, "
        "\"new_concert\": true}'::jsonb"
    )
