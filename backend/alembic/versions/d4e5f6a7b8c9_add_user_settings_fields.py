"""add show_predicted_setlist and notification_settings to users

Revision ID: d4e5f6a7b8c9
Revises: c3d4e5f6a7b8
Create Date: 2026-06-01 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op

revision: str = 'd4e5f6a7b8c9'
down_revision: Union[str, None] = 'c3d4e5f6a7b8'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

_NOTIF_DEFAULT = '\'{"delivery": true, "before_concert": true}\'::jsonb'


def upgrade() -> None:
    op.execute(
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS show_predicted_setlist "
        "BOOLEAN NOT NULL DEFAULT true"
    )
    op.execute(
        f"ALTER TABLE users ADD COLUMN IF NOT EXISTS notification_settings "
        f"JSONB DEFAULT {_NOTIF_DEFAULT}"
    )
    # NULL 행 기본값으로 채우기
    op.execute(
        f"UPDATE users SET notification_settings = {_NOTIF_DEFAULT} "
        "WHERE notification_settings IS NULL"
    )
    # NOT NULL + DEFAULT 확정
    op.execute(
        "ALTER TABLE users ALTER COLUMN notification_settings SET NOT NULL"
    )
    op.execute(
        f"ALTER TABLE users ALTER COLUMN notification_settings SET DEFAULT {_NOTIF_DEFAULT}"
    )


def downgrade() -> None:
    op.execute("ALTER TABLE users DROP COLUMN IF EXISTS notification_settings")
    op.execute("ALTER TABLE users DROP COLUMN IF EXISTS show_predicted_setlist")
