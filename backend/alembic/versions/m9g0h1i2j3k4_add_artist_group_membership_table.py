"""add artist group membership table

Revision ID: m9g0h1i2j3k4
Revises: l8f9g0h1i2j3
Create Date: 2026-08-31 23:16:11.428490

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = 'm9g0h1i2j3k4'
down_revision: Union[str, None] = 'l8f9g0h1i2j3'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'artist_group_memberships',
        sa.Column('id', UUID(as_uuid=True), primary_key=True),
        sa.Column('member_canonical_id', UUID(as_uuid=True), sa.ForeignKey('canonical_artists.id'), nullable=False),
        sa.Column('group_canonical_id', UUID(as_uuid=True), sa.ForeignKey('canonical_artists.id'), nullable=False),
        sa.Column('is_current', sa.Boolean(), nullable=False, server_default=sa.text('true')),
        sa.Column('source', sa.String(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=True),
        sa.UniqueConstraint('member_canonical_id', 'group_canonical_id', name='uq_artist_group_membership'),
    )


def downgrade() -> None:
    op.drop_table('artist_group_memberships')
