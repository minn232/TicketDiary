"""add new_concert to users.notification_settings default

Revision ID: q7l8m9n0o1p2
Revises: p6k7l8m9n0o1
Create Date: 2026-07-20 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op

revision: str = 'q7l8m9n0o1p2'
down_revision: Union[str, None] = 'p6k7l8m9n0o1'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute(
        "ALTER TABLE users ALTER COLUMN notification_settings "
        "SET DEFAULT '{\"delivery\": true, \"before_concert\": true, \"ticketing\": true, "
        "\"new_concert\": true}'::jsonb"
    )


def downgrade() -> None:
    op.execute(
        "ALTER TABLE users ALTER COLUMN notification_settings "
        "SET DEFAULT '{\"delivery\": true, \"before_concert\": true, \"ticketing\": true}'::jsonb"
    )
