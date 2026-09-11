#!/usr/bin/env bash
# 更新：导入镜像 tar（如有）→ 备份数据库 → up -d 切到新版本。
# 新版本号来自 casdoor.local.env 的 CASDOOR_VERSION（由构建机 release 写回后随代码同步过来）。
set -euo pipefail

. "$(dirname "$0")/common.sh"

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "[dry-run] $0（跳过导入、备份与更新）"
  exit 0
fi

IMAGES_DIR="${IMAGES_DIR:-$(cd "$STACK_DIR/.." && pwd)/images}"

if [ -d "$IMAGES_DIR" ] && ls "$IMAGES_DIR"/*.tar.gz >/dev/null 2>&1; then
  for tarball in "$IMAGES_DIR"/*.tar.gz; do
    echo "==> 导入镜像: $tarball"
    docker load -i "$tarball"
  done
fi

bash "$STACK_DIR/scripts/backup.sh"

load_stack_env
need_compose
require_image "${CASDOOR_IMAGE_NAME}:${CASDOOR_VERSION}"
$COMPOSE_CMD up -d
echo "---- 容器状态 ----"
$COMPOSE_CMD ps
