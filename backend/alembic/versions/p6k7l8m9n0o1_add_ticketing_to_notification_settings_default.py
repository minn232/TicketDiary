"""add ticketing to users.notification_settings default

Revision ID: p6k7l8m9n0o1
Revises: o5j6k7l8m9n0
Create Date: 2026-07-20 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op

revision: str = 'p6k7l8m9n0o1'
down_revision: Union[str, None] = 'o5j6k7l8m9n0'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute(
        "ALTER TABLE users ALTER COLUMN notification_settings "
        "SET DEFAULT '{\"delivery\": true, \"before_concert\": true, \"ticketing\": true}'::jsonb"
    )


def downgrade() -> None:
    op.execute(
        "ALTER TABLE users ALTER COLUMN notification_settings "
        "SET DEFAULT '{\"delivery\": true, \"before_concert\": true}'::jsonb"
    )
