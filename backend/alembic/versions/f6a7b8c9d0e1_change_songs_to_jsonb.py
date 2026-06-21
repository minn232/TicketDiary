"""change real_setlists and pre_setlists songs column from text to jsonb

Revision ID: f6a7b8c9d0e1
Revises: e5f6a7b8c9d0
Create Date: 2026-06-08 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op

revision: str = 'f6a7b8c9d0e1'
down_revision: Union[str, None] = 'e5f6a7b8c9d0'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute(
        "ALTER TABLE real_setlists ALTER COLUMN songs TYPE JSONB USING songs::jsonb"
    )
    op.execute(
        "ALTER TABLE pre_setlists ALTER COLUMN songs TYPE JSONB USING songs::jsonb"
    )


def downgrade() -> None:
    op.execute(
        "ALTER TABLE real_setlists ALTER COLUMN songs TYPE TEXT USING songs::text"
    )
    op.execute(
        "ALTER TABLE pre_setlists ALTER COLUMN songs TYPE TEXT USING songs::text"
    )
