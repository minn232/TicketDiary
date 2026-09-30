"""add itunes_catalog_cache

Revision ID: a1x2y3z4b5c6
Revises: x0r1s2t3u4v5
Create Date: 2026-09-29 00:00:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB, UUID

revision: str = 'a1x2y3z4b5c6'
down_revision: Union[str, None] = 'x0r1s2t3u4v5'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "itunes_catalog_cache",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("itunes_artist_id", sa.String(), nullable=False, unique=True),
        sa.Column("tracks", JSONB(), nullable=False),
        sa.Column("fetched_at", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("itunes_catalog_cache")
