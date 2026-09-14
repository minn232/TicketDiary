"""add admin_reviewed_at to concerts

Revision ID: q3k4l5m6n7o8
Revises: p2j3k4l5m6n7
Create Date: 2026-09-09 00:00:00.000001

"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'q3k4l5m6n7o8'
down_revision: Union[str, None] = 'p2j3k4l5m6n7'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # admin 페이지에서 사람이 이 공연의 아티스트를 확인/수정했는지 - NULL이면 미검수. KOPIS/크롤링/
    # LLM 등 자동 파이프라인이 artist_name을 바꾸면 이 값을 다시 NULL로 되돌려서 항상 최신
    # 데이터 기준 검수 상태를 유지한다
    op.add_column(
        'concerts',
        sa.Column('admin_reviewed_at', sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column('concerts', 'admin_reviewed_at')
