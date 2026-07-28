"""add performance_date to real_setlists

Revision ID: f2a3b4c5d6e7
Revises: e1z2a3b4c5d6
Create Date: 2026-07-28 00:30:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'f2a3b4c5d6e7'
down_revision: Union[str, None] = 'e1z2a3b4c5d6'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column('real_setlists', sa.Column('performance_date', sa.Date(), nullable=True))
    # 기존 행은 concert_id당 하나뿐이었으므로 concert.start_date로 백필
    op.execute(
        """
        UPDATE real_setlists
        SET performance_date = concerts.start_date::date
        FROM concerts
        WHERE real_setlists.concert_id = concerts.id
        """
    )
    op.alter_column('real_setlists', 'performance_date', nullable=False)
    op.drop_constraint('uq_real_setlists_concert', 'real_setlists', type_='unique')
    op.create_unique_constraint('uq_real_setlists_concert_date', 'real_setlists', ['concert_id', 'performance_date'])


def downgrade() -> None:
    op.drop_constraint('uq_real_setlists_concert_date', 'real_setlists', type_='unique')
    op.create_unique_constraint('uq_real_setlists_concert', 'real_setlists', ['concert_id'])
    op.drop_column('real_setlists', 'performance_date')
