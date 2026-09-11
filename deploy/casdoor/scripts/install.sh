#!/usr/bin/env bash
# 首次部署：环境检查 → 起栈。由 deploy/sso install 调用，也可直接运行。
set -euo pipefail

. "$(dirname "$0")/common.sh"

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "[dry-run] $0（跳过检查与起栈）"
  exit 0
fi

load_stack_env
need_compose

if [ ! -f "$STACK_DIR/.env" ]; then
  echo "ERROR: 缺少 deploy/casdoor/.env" >&2
  echo "  复制模板并修改: cp deploy/casdoor/.env.example deploy/casdoor/.env" >&2
  exit 1
fi
case "${MYSQL_ROOT_PASSWORD:-}" in
  ""|CHANGE_ME*)
    echo "ERROR: MYSQL_ROOT_PASSWORD 仍是占位值，请先在 deploy/casdoor/.env 中修改" >&2
    exit 1
    ;;
esac

if [ ! -f "$STACK_DIR/conf/app.conf" ]; then
  echo "ERROR: 缺少 deploy/casdoor/conf/app.conf" >&2
  echo "  复制模板并修改: cp deploy/casdoor/conf/app.conf.example deploy/casdoor/conf/app.conf" >&2
  echo "  注意: app.conf 里 dataSourceName 的口令必须与 .env 的 MYSQL_ROOT_PASSWORD 一致" >&2
  exit 1
fi

require_image "${CASDOOR_IMAGE_NAME}:${CASDOOR_VERSION}"
require_image "${MYSQL_IMAGE}"

$COMPOSE_CMD up -d
echo "---- 容器状态 ----"
$COMPOSE_CMD ps
echo ""
echo "安装完成。访问 http://<服务器地址>:${CASDOOR_PORT} ，默认账号 admin/123，登录后立即改密。"
