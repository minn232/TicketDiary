"""add gin index to concert_follows.concerts

Revision ID: z6u7v8w9x0y1
Revises: y5t6u7v8w9x0
Create Date: 2026-07-23 00:00:00.000003

"""
from typing import Sequence, Union

from alembic import op

revision: str = 'z6u7v8w9x0y1'
down_revision: Union[str, None] = 'y5t6u7v8w9x0'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_index(
        "ix_concert_follows_concerts_gin",
        "concert_follows",
        ["concerts"],
        postgresql_using="gin",
    )


def downgrade() -> None:
    op.drop_index("ix_concert_follows_concerts_gin", table_name="concert_follows")
