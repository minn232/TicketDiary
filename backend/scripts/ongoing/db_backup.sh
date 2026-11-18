#!/usr/bin/env bash
# 일 1회 DB 백업(pg_dump) - 7일 지난 파일은 삭제. 개인정보 처리방침의 "백업 7일 보관"과 맞춘 값이라
# KEEP_DAYS를 바꾸면 방침 문구도 같이 바꿀 것
#
# 서버 cron(UTC라 KST 04:30 = UTC 19:30):
#   30 19 * * * /bin/bash /home/ubuntu/TicketDiary/backend/scripts/ongoing/db_backup.sh >> /home/ubuntu/db_backups/backup.log 2>&1
# 인증은 ~/.pgpass를 사용(비밀번호는 이 파일에 없음)
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-$HOME/db_backups}"
KEEP_DAYS="${KEEP_DAYS:-7}"
STAMP="$(date -u +%Y%m%d_%H%M%S)"
FINAL="$BACKUP_DIR/ticketdiary_${STAMP}.dump"
TMP="$FINAL.part"

# 개인정보가 들어 있으므로 본인만 읽을 수 있게
umask 077
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# .part로 먼저 받고 끝까지 성공했을 때만 이름을 바꿈 - 도중에 실패한 반쪽 파일이 백업처럼 남지 않게
trap 'rm -f "$TMP"' EXIT
pg_dump -w -U ticketdiary -d ticketdiary -h localhost -Fc -f "$TMP"
mv "$TMP" "$FINAL"
echo "$(date -u +%FT%TZ) 백업 완료: $FINAL ($(du -h "$FINAL" | cut -f1))"

# 삭제는 백업이 성공한 뒤에만(set -e로 위에서 실패하면 여기까지 안 옴) - 실패한 날 옛 백업까지 지우지 않음
find "$BACKUP_DIR" -maxdepth 1 -name 'ticketdiary_*.dump' -mtime "+$((KEEP_DAYS - 1))" -print -delete \
  | sed 's/^/삭제: /'
