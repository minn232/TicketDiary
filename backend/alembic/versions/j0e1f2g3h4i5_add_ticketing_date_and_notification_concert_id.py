"""add concerts.ticketing_date and notifications.concert_id

Revision ID: j0e1f2g3h4i5
Revises: i9d0e1f2g3h4
Create Date: 2026-06-30 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = 'j0e1f2g3h4i5'
down_revision: Union[str, None] = 'i9d0e1f2g3h4'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('concerts', sa.Column('ticketing_date', sa.DateTime(timezone=True), nullable=True))

    op.add_column('notifications', sa.Column('concert_id', sa.UUID(), nullable=True))
    op.create_foreign_key(
        'notifications_concert_id_fkey',
        'notifications', 'concerts',
        ['concert_id'], ['id'],
        ondelete='SET NULL',
    )


def downgrade() -> None:
    op.drop_constraint('notifications_concert_id_fkey', 'notifications', type_='foreignkey')
    op.drop_column('notifications', 'concert_id')
    op.drop_column('concerts', 'ticketing_date')
