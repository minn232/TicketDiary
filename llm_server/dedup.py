import sqlite3
import threading
from datetime import datetime, timezone

from config import settings

# 처리 완료 ID 장부. "이미 콜백까지 성공적으로 보낸 항목을 다시 처리하지 않기 위한
# 스킵용 장부"이지, 미완료 항목을 여기서 추적/재개하지 않는다. 콜백 전송에 실패했거나
# 처리 중 프로세스가 죽어서 기록이 없으면, 다음날 같은 ID가 다시 와도 그냥 신규 요청처럼
# 처음부터 재처리된다 (그게 원하는 동작 - 재시도는 백엔드 배치 쪽이 이미 담당).
#
# kind로 네임스페이스를 나눠서("crawl"/"artist"/"diary") concert_id/ticket_id가
# 우연히 같은 문자열이어도 서로 다른 항목으로 취급되게 한다.

_lock = threading.Lock()


def _get_conn() -> sqlite3.Connection:
    conn = sqlite3.connect(settings.DEDUP_DB_PATH)
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS processed (
            kind TEXT NOT NULL,
            item_id TEXT NOT NULL,
            processed_at TEXT NOT NULL,
            PRIMARY KEY (kind, item_id)
        )
        """
    )
    return conn


def is_processed(kind: str, item_id: str) -> bool:
    with _lock, _get_conn() as conn:
        row = conn.execute(
            "SELECT 1 FROM processed WHERE kind = ? AND item_id = ?", (kind, item_id)
        ).fetchone()
        return row is not None


def mark_processed(kind: str, item_id: str) -> None:
    with _lock, _get_conn() as conn:
        conn.execute(
            "INSERT OR REPLACE INTO processed (kind, item_id, processed_at) VALUES (?, ?, ?)",
            (kind, item_id, datetime.now(timezone.utc).isoformat()),
        )
        conn.commit()
