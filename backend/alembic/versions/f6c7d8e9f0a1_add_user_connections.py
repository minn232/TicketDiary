"""add nearby_codes, nearby_sightings, user_connections, users.share_next_concert

Revision ID: f6c7d8e9f0a1
Revises: e5b6c7d8e9f0
Create Date: 2026-10-13 00:00:00.000000

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = 'f6c7d8e9f0a1'
down_revision: Union[str, None] = 'e5b6c7d8e9f0'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 연결 카드에서 내 다음 공연을 상대에게 보여줄지 (기본 공개)
    op.add_column('users', sa.Column('share_next_concert', sa.Boolean(), nullable=False, server_default=sa.text('true')))
    # 폰 맞대기 BLE 광고 코드 (만료된 것도 오프라인 판정 해석용으로 남김)
    op.create_table(
        'nearby_codes',
        sa.Column('id', postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column('user_id', postgresql.UUID(as_uuid=True), sa.ForeignKey('users.id', ondelete='CASCADE'), nullable=False),
        sa.Column('code', sa.String(), nullable=False, index=True),
        sa.Column('valid_from', sa.DateTime(timezone=True), nullable=False),
        sa.Column('valid_until', sa.DateTime(timezone=True), nullable=False),
    )
    # 각 폰이 올린 맞댐 판정
    op.create_table(
        'nearby_sightings',
        sa.Column('id', postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column('observer_user_id', postgresql.UUID(as_uuid=True), sa.ForeignKey('users.id', ondelete='CASCADE'), nullable=False),
        sa.Column('observed_user_id', postgresql.UUID(as_uuid=True), sa.ForeignKey('users.id', ondelete='CASCADE'), nullable=False),
        sa.Column('rssi', sa.Integer(), nullable=True),
        sa.Column('seen_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index('ix_nearby_sightings_pair', 'nearby_sightings', ['observer_user_id', 'observed_user_id'])
    # 유저 간 연결 (user_a_id < user_b_id로 쌍당 1행)
    op.create_table(
        'user_connections',
        sa.Column('id', postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column('user_a_id', postgresql.UUID(as_uuid=True), sa.ForeignKey('users.id', ondelete='CASCADE'), nullable=False),
        sa.Column('user_b_id', postgresql.UUID(as_uuid=True), sa.ForeignKey('users.id', ondelete='CASCADE'), nullable=False, index=True),
        sa.Column('a_confirmed_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('b_confirmed_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('requested_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('connected_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('last_met_at', sa.DateTime(timezone=True), nullable=True),
        sa.UniqueConstraint('user_a_id', 'user_b_id', name='uq_user_connection'),
    )


def downgrade() -> None:
    op.drop_table('user_connections')
    op.drop_index('ix_nearby_sightings_pair', table_name='nearby_sightings')
    op.drop_table('nearby_sightings')
    op.drop_table('nearby_codes')
    op.drop_column('users', 'share_next_concert')
