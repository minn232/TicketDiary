"""make concerts.kopis_id unique

Revision ID: b2y3z4a5c6d7
Revises: a1x2y3z4b5c6
Create Date: 2026-09-30 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op

revision: str = 'b2y3z4a5c6d7'
down_revision: Union[str, None] = 'a1x2y3z4b5c6'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


# 기존 일반 인덱스를 같은 이름의 유니크 인덱스로 교체 - 동시 upsert로 같은 공연이 두 번 들어가는 걸
# DB에서 막음(적용 전 서버 DB 중복 0건 확인)
def upgrade() -> None:
    op.drop_index("ix_concerts_kopis_id", table_name="concerts")
    op.create_index("ix_concerts_kopis_id", "concerts", ["kopis_id"], unique=True)


def downgrade() -> None:
    op.drop_index("ix_concerts_kopis_id", table_name="concerts")
    op.create_index("ix_concerts_kopis_id", "concerts", ["kopis_id"], unique=False)
