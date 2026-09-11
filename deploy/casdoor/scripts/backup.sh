#!/usr/bin/env bash
# 备份数据库到 backup/（gitignore），保留最近 BACKUP_KEEP 份（默认 10）。
set -euo pipefail

. "$(dirname "$0")/common.sh"

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "[dry-run] $0（跳过备份）"
  exit 0
fi

load_stack_env
need_compose

BACKUP_DIR="${BACKUP_DIR:-$STACK_DIR/backup}"
KEEP="${BACKUP_KEEP:-10}"
mkdir -p "$BACKUP_DIR"

if ! $COMPOSE_CMD exec -T db true >/dev/null 2>&1; then
  echo "db 容器未运行，跳过备份"
  exit 0
fi

stamp="$(date +%Y%m%d-%H%M%S)"
outfile="$BACKUP_DIR/casdoor-${stamp}-${CASDOOR_VERSION}.sql.gz"
# 口令取容器内的环境变量，避免在宿主命令行上展开
$COMPOSE_CMD exec -T db sh -c 'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines casdoor' | gzip > "$outfile"
echo "已备份: $outfile"

ls -1t "$BACKUP_DIR"/casdoor-*.sql.gz 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
  rm -f "$old"
  echo "清理过期备份: $old"
done
