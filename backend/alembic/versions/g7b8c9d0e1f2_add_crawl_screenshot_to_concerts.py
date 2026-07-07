"""add crawl_screenshot_url to concerts

Revision ID: g7b8c9d0e1f2
Revises: f6a7b8c9d0e1
Create Date: 2026-06-28 00:00:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'g7b8c9d0e1f2'
down_revision: Union[str, None] = 'f6a7b8c9d0e1'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('concerts', sa.Column('crawl_screenshot_url', sa.String(), nullable=True))


def downgrade() -> None:
    op.drop_column('concerts', 'crawl_screenshot_url')
