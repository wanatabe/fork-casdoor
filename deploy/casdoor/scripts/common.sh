#!/usr/bin/env bash
# 公共函数：加载栈环境变量、探测 compose 命令。被其他脚本 source，不直接执行。

STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"

load_stack_env() {
  cd "$STACK_DIR"
  set -a
  . ./casdoor.local.env
  if [ -f ./.env ]; then
    . ./.env
  fi
  set +a
}

need_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
  else
    echo "ERROR: 未找到 docker compose（插件或 docker-compose 二者均可）" >&2
    exit 1
  fi
}

require_image() {
  if ! docker image inspect "$1" >/dev/null 2>&1; then
    echo "ERROR: 本机不存在镜像：$1" >&2
    echo "  离线部署请先把 tar 包放入 deploy/images/，再执行: bash deploy/sso images load" >&2
    exit 1
  fi
}
