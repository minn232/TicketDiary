"""change concert_photo_urls to jsonb

Revision ID: a1b2c3d4e5f6
Revises: 300384b2bd10
Create Date: 2026-05-15 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = 'a1b2c3d4e5f6'
down_revision: Union[str, None] = '300384b2bd10'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.alter_column(
        'tickets',
        'concert_photo_urls',
        type_=postgresql.JSONB(),
        postgresql_using='concert_photo_urls::jsonb',
        existing_type=sa.Text(),
        existing_nullable=True,
    )


def downgrade() -> None:
    op.alter_column(
        'tickets',
        'concert_photo_urls',
        type_=sa.Text(),
        postgresql_using='concert_photo_urls::text',
        existing_type=postgresql.JSONB(),
        existing_nullable=True,
    )
