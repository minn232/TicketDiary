"""add crawl_lineup_seeded_at to concerts

Revision ID: s5m6n7o8p9q0
Revises: r4l5m6n7o8p9
Create Date: 2026-09-11 00:00:00.000001

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 's5m6n7o8p9q0'
down_revision: Union[str, None] = 'r4l5m6n7o8p9'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 다인원/페스티벌 공연에서 크롤링 결과로 KOPIS 원본을 1회 교체했는지 - NULL이면 아직 전
    # (처음 한 번은 통째로 교체), 값이 있으면 그 이후부터는 합집합만(merge_crawl_artist_names 참고)
    op.add_column(
        'concerts',
        sa.Column('crawl_lineup_seeded_at', sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column('concerts', 'crawl_lineup_seeded_at')
