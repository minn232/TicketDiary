"""add artist group membership table

Revision ID: 64fc497014a8
Revises: 1318c8becb68
Create Date: 2026-08-31 23:16:11.428490

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = '64fc497014a8'
down_revision: Union[str, None] = '1318c8becb68'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table('artist_group_memberships',
    sa.Column('id', sa.UUID(), nullable=False),
    sa.Column('member_canonical_id', sa.UUID(), nullable=False),
    sa.Column('group_canonical_id', sa.UUID(), nullable=False),
    sa.Column('is_current', sa.Boolean(), nullable=False),
    sa.Column('source', sa.String(), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), nullable=True),
    sa.ForeignKeyConstraint(['group_canonical_id'], ['canonical_artists.id'], ),
    sa.ForeignKeyConstraint(['member_canonical_id'], ['canonical_artists.id'], ),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('member_canonical_id', 'group_canonical_id', name='uq_artist_group_membership')
    )


def downgrade() -> None:
    op.drop_table('artist_group_memberships')
