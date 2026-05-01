"""init

Revision ID: 300384b2bd10
Revises:
Create Date: 2026-05-01 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision: str = '300384b2bd10'
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # users
    op.create_table(
        'users',
        sa.Column('id', sa.UUID(), nullable=False),
        sa.Column('kakao_id', sa.String(), nullable=True),
        sa.Column('guest_token', sa.String(), nullable=True),
        sa.Column('nickname', sa.String(), nullable=True),
        sa.Column('profile_image_url', sa.String(), nullable=True),
        sa.Column('role', sa.Enum('kakao_user', 'guest', name='userrole'), nullable=True),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(op.f('ix_users_kakao_id'), 'users', ['kakao_id'], unique=True)
    op.create_index(op.f('ix_users_guest_token'), 'users', ['guest_token'], unique=True)

    # concerts
    op.create_table(
        'concerts',
        sa.Column('id', sa.UUID(), nullable=False),
        sa.Column('kopis_id', sa.String(), nullable=True),
        sa.Column('name', sa.String(), nullable=False),
        sa.Column('artist_name', postgresql.ARRAY(sa.String()), nullable=False),
        sa.Column('venue', sa.String(), nullable=True),
        sa.Column('start_date', sa.DateTime(timezone=True), nullable=False),
        sa.Column('end_date', sa.DateTime(timezone=True), nullable=False),
        sa.Column('genre', postgresql.ARRAY(sa.String()), nullable=True),
        sa.Column('poster_url', sa.String(), nullable=True),
        sa.Column('description', sa.Text(), nullable=True),
        sa.Column('price', postgresql.JSONB(), nullable=True),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(op.f('ix_concerts_kopis_id'), 'concerts', ['kopis_id'], unique=False)

    # tickets
    op.create_table(
        'tickets',
        sa.Column('id', sa.UUID(), nullable=False),
        sa.Column('user_id', sa.UUID(), nullable=False),
        sa.Column('concert_id', sa.UUID(), nullable=True),
        sa.Column('status', sa.Enum('before_delivery', 'before_concert', 'after_concert', name='ticketstatus'), nullable=True),
        sa.Column('delivery_date', sa.DateTime(timezone=True), nullable=True),
        sa.Column('ticketing_site', sa.String(), nullable=True),
        sa.Column('price', sa.Integer(), nullable=True),
        sa.Column('seat_type', sa.String(), nullable=True),
        sa.Column('ticket_image_url', sa.String(), nullable=True),
        sa.Column('review', sa.Text(), nullable=True),
        sa.Column('concert_photo_urls', sa.Text(), nullable=True),
        sa.Column('is_first_day', sa.Boolean(), nullable=True),
        sa.Column('is_last_day', sa.Boolean(), nullable=True),
        sa.ForeignKeyConstraint(['user_id'], ['users.id']),
        sa.ForeignKeyConstraint(['concert_id'], ['concerts.id']),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('user_id', 'concert_id', name='uq_tickets_user_concert'),
    )
    op.create_index(op.f('ix_tickets_user_id'), 'tickets', ['user_id'], unique=False)
    op.create_index(op.f('ix_tickets_concert_id'), 'tickets', ['concert_id'], unique=False)

    # artist_follows
    op.create_table(
        'artist_follows',
        sa.Column('id', sa.UUID(), nullable=False),
        sa.Column('user_id', sa.UUID(), nullable=False),
        sa.Column('artists', postgresql.JSONB(), nullable=False, server_default=sa.text("'[]'::jsonb")),
        sa.ForeignKeyConstraint(['user_id'], ['users.id']),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('user_id', name='uq_artist_follows_user'),
    )

    # concert_follows
    op.create_table(
        'concert_follows',
        sa.Column('id', sa.UUID(), nullable=False),
        sa.Column('user_id', sa.UUID(), nullable=False),
        sa.Column('concerts', postgresql.JSONB(), nullable=False, server_default=sa.text("'[]'::jsonb")),
        sa.ForeignKeyConstraint(['user_id'], ['users.id']),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('user_id', name='uq_concert_follows_user'),
    )

    # news_feeds
    op.create_table(
        'news_feeds',
        sa.Column('id', sa.UUID(), nullable=False),
        sa.Column('user_id', sa.UUID(), nullable=False),
        sa.Column('concert_id', sa.UUID(), nullable=False),
        sa.Column('artist_name', sa.String(), nullable=False),
        sa.Column('is_read', sa.Boolean(), nullable=True, server_default=sa.text('false')),
        sa.ForeignKeyConstraint(['user_id'], ['users.id']),
        sa.ForeignKeyConstraint(['concert_id'], ['concerts.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(op.f('ix_news_feeds_user_id'), 'news_feeds', ['user_id'], unique=False)
    op.create_index(op.f('ix_news_feeds_concert_id'), 'news_feeds', ['concert_id'], unique=False)

    # notifications
    op.create_table(
        'notifications',
        sa.Column('id', sa.UUID(), nullable=False),
        sa.Column('user_id', sa.UUID(), nullable=False),
        sa.Column('ticket_id', sa.UUID(), nullable=True),
        sa.Column('type', sa.Enum('day_before', 'concert_day', 'delivery_day', 'ticketing_day', 'new_concert', name='notificationtype'), nullable=False),
        sa.Column('title', sa.String(), nullable=False),
        sa.Column('body', sa.String(), nullable=False),
        sa.Column('is_sent', sa.Boolean(), nullable=True, server_default=sa.text('false')),
        sa.Column('scheduled_at', sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(['user_id'], ['users.id']),
        sa.ForeignKeyConstraint(['ticket_id'], ['tickets.id']),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(op.f('ix_notifications_user_id'), 'notifications', ['user_id'], unique=False)

    # real_setlists
    op.create_table(
        'real_setlists',
        sa.Column('id', sa.UUID(), nullable=False),
        sa.Column('concert_id', sa.UUID(), nullable=False),
        sa.Column('setlistfm_id', sa.String(), nullable=True),
        sa.Column('songs', sa.Text(), nullable=False),
        sa.Column('is_user_edited', sa.Boolean(), nullable=True, server_default=sa.text('false')),
        sa.Column('edited_user_nickname', sa.String(), nullable=True),
        sa.ForeignKeyConstraint(['concert_id'], ['concerts.id']),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('concert_id', name='uq_real_setlists_concert'),
    )

    # pre_setlists
    op.create_table(
        'pre_setlists',
        sa.Column('id', sa.UUID(), nullable=False),
        sa.Column('concert_id', sa.UUID(), nullable=False),
        sa.Column('setlistfm_id', sa.String(), nullable=True),
        sa.Column('songs', sa.Text(), nullable=False),
        sa.Column('is_user_edited', sa.Boolean(), nullable=True, server_default=sa.text('false')),
        sa.Column('edited_user_nickname', sa.String(), nullable=True),
        sa.ForeignKeyConstraint(['concert_id'], ['concerts.id']),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('concert_id', name='uq_pre_setlists_concert'),
    )

    # timetables
    op.create_table(
        'timetables',
        sa.Column('id', sa.UUID(), nullable=False),
        sa.Column('concert_id', sa.UUID(), nullable=False),
        sa.Column('contents', postgresql.JSONB(), nullable=False, server_default=sa.text("'[]'::jsonb")),
        sa.ForeignKeyConstraint(['concert_id'], ['concerts.id']),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('concert_id', name='uq_timetables_concert'),
    )


def downgrade() -> None:
    op.drop_table('timetables')
    op.drop_table('pre_setlists')
    op.drop_table('real_setlists')
    op.drop_index(op.f('ix_notifications_user_id'), table_name='notifications')
    op.drop_table('notifications')
    op.drop_index(op.f('ix_news_feeds_concert_id'), table_name='news_feeds')
    op.drop_index(op.f('ix_news_feeds_user_id'), table_name='news_feeds')
    op.drop_table('news_feeds')
    op.drop_table('concert_follows')
    op.drop_table('artist_follows')
    op.drop_index(op.f('ix_tickets_concert_id'), table_name='tickets')
    op.drop_index(op.f('ix_tickets_user_id'), table_name='tickets')
    op.drop_table('tickets')
    op.drop_index(op.f('ix_concerts_kopis_id'), table_name='concerts')
    op.drop_table('concerts')
    op.drop_index(op.f('ix_users_guest_token'), table_name='users')
    op.drop_index(op.f('ix_users_kakao_id'), table_name='users')
    op.drop_table('users')
    op.execute('DROP TYPE IF EXISTS notificationtype')
    op.execute('DROP TYPE IF EXISTS ticketstatus')
    op.execute('DROP TYPE IF EXISTS userrole')
