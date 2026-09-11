#!/usr/bin/env bash
# SSO（casdoor fork）离线部署统一 CLI。
# 用法: bash deploy/sso <子命令> [--dry-run] [--all]
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGES_DIR="${IMAGES_DIR:-$DEPLOY_DIR/images}"
REPO_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"

# shellcheck source=../casdoor/scripts/common.sh
. "$DEPLOY_DIR/casdoor/scripts/common.sh"
# common.sh 会把 STACK_DIR 算成它自己的上级（在 sso.sh 语境下是 deploy/），这里改回业务栈目录
STACK_DIR="$DEPLOY_DIR/casdoor"

usage() {
  cat <<'EOF'
SSO (casdoor fork) 离线部署 CLI —— 用法: bash deploy/sso <子命令> [选项]

构建机（可访问外网，用于拉基础镜像）:
  release          构建镜像 → 写回版本号到 deploy/casdoor/casdoor.local.env
                    → 导出镜像 tar 到 deploy/images/（仅当前版本 + mysql）
  release --all    同上，但导出本机全部 casdoor 镜像 tag（备多套版本时用）
  images save      仅导出镜像（不构建）
  images save --all

部署机（内网离线）:
  images load      导入 deploy/images/ 下全部镜像 tar
  install          首次部署：环境检查（.env、app.conf、镜像）→ 起栈
  update           更新：导入镜像 → 备份数据库 → up -d
  backup           手动备份数据库（update 前也会自动备份）
  status           容器状态、当前版本、健康检查
  start / stop     启停整个栈

选项:
  --dry-run        只打印将执行的命令，不实际执行
  --all            与 release / images save 组合使用
  --help           显示本帮助

环境旋钮（可选）: IMAGES_DIR=... PRUNE_STALE_TARS=0 BACKUP_DIR=... BACKUP_KEEP=N
EOF
}

DRY_RUN=0
ALL=0
SUB=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --all) ALL=1 ;;
    --help|-h) usage; exit 0 ;;
    -*) echo "未知选项: $arg" >&2; usage; exit 1 ;;
    *) [ -z "$SUB" ] && SUB="$arg" || SUB="$SUB $arg" ;;
  esac
done

run() {
  if [ "$DRY_RUN" = "1" ]; then echo "[dry-run] $*"; else "$@"; fi
}

run_sh() {
  if [ "$DRY_RUN" = "1" ]; then echo "[dry-run] $*"; else bash -c "$*"; fi
}

cmd_release() {
  cd "$REPO_ROOT"
  set -a
  . "$STACK_DIR/casdoor.local.env"
  set +a

  version="$(tr -d '[:space:]' < VERSION)"
  if [ -z "$version" ]; then
    echo "ERROR: 根目录 VERSION 文件为空" >&2
    exit 1
  fi
  sha="$(git rev-parse --short HEAD)"
  if [ -n "$(git status --porcelain)" ]; then
    sha="${sha}-dirty"
  fi
  tag="${version}-${sha}"
  # 传给 cmd_images_save：dry-run 时 env 文件未写回，也必须预览到新版本
  export RELEASE_TAG="$tag"
  image="${CASDOOR_IMAGE_NAME}:${tag}"

  echo "==> 构建镜像 $image（target: STANDARD）"
  run docker build --target STANDARD -t "$image" .

  echo "==> 写回版本号 CASDOOR_VERSION=$tag"
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] 更新 $STACK_DIR/casdoor.local.env"
  else
    grep -v '^CASDOOR_VERSION=' "$STACK_DIR/casdoor.local.env" > "$STACK_DIR/casdoor.local.env.tmp"
    printf 'CASDOOR_VERSION=%s\n' "$tag" >> "$STACK_DIR/casdoor.local.env.tmp"
    mv "$STACK_DIR/casdoor.local.env.tmp" "$STACK_DIR/casdoor.local.env"
  fi

  echo "==> 确认数据库基础镜像 $MYSQL_IMAGE 在本机"
  if docker image inspect "$MYSQL_IMAGE" >/dev/null 2>&1; then
    echo "已存在: $MYSQL_IMAGE"
  else
    run docker pull "$MYSQL_IMAGE"
  fi

  cmd_images_save
  echo ""
  echo "完成。下一步: 把 deploy/ 目录与 images/ 内 tar 传到服务器，执行 bash deploy/sso update"
}

cmd_images_save() {
  cd "$STACK_DIR"
  load_stack_env
  need_compose

  mkdir -p "$IMAGES_DIR"

  if [ "$ALL" = "1" ]; then
    images="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "^${CASDOOR_IMAGE_NAME}:" | grep -v '<none>' || true)"
    if [ -z "$images" ]; then
      echo "ERROR: 本机没有任何 ${CASDOOR_IMAGE_NAME} 镜像" >&2
      exit 1
    fi
    images="$images
$MYSQL_IMAGE"
  else
    images="${CASDOOR_IMAGE_NAME}:${RELEASE_TAG:-$CASDOOR_VERSION}
$MYSQL_IMAGE"
  fi

  for image in $images; do
    fname="${IMAGES_DIR}/$(printf '%s' "$image" | sed 's|[:/@]|_|g').tar.gz"
    echo "==> 导出 $image -> $fname"
    run_sh "docker save '$image' | gzip > '$fname'"
  done

  # 默认（非 --all）导出后清理过时 tar，保证 images/ 只含当前版本，物理介质装得下
  if [ "$ALL" != "1" ] && [ "${PRUNE_STALE_TARS:-1}" = "1" ]; then
    keep="$(printf '%s' "$images" | sed 's|[:/@]|_|g')"
    for tarball in "$IMAGES_DIR"/*.tar.gz; do
      [ -f "$tarball" ] || continue
      base="$(basename "$tarball" .tar.gz)"
      case "$keep" in
        *"$base"*) ;;
        *) echo "==> 清理过时导出: $tarball"; run rm -f "$tarball" ;;
      esac
    done
  fi
}

cmd_images_load() {
  if [ ! -d "$IMAGES_DIR" ]; then
    echo "ERROR: 目录不存在: $IMAGES_DIR" >&2
    exit 1
  fi
  found=0
  for tarball in "$IMAGES_DIR"/*.tar.gz; do
    [ -f "$tarball" ] || continue
    found=1
    echo "==> 导入 $tarball"
    run docker load -i "$tarball"
  done
  if [ "$found" != "1" ]; then
    echo "ERROR: $IMAGES_DIR 下没有 *.tar.gz" >&2
    exit 1
  fi
}

cmd_status() {
  load_stack_env
  need_compose
  echo "当前版本: CASDOOR_VERSION=$CASDOOR_VERSION"
  $COMPOSE_CMD ps
  echo "--- 健康检查 ---"
  if curl -sf "http://127.0.0.1:${CASDOOR_PORT}/api/health" >/dev/null 2>&1; then
    echo "casdoor /api/health: OK"
  else
    echo "casdoor /api/health: 不可达（宿主机无 curl 或服务未就绪时，以上方容器状态为准）"
  fi
}

cmd_stack() {
  load_stack_env
  need_compose
  cd "$STACK_DIR"
  $COMPOSE_CMD "$@"
}

case "$SUB" in
  release) cmd_release ;;
  "images save") cmd_images_save ;;
  "images load") cmd_images_load ;;
  install) run bash "$STACK_DIR/scripts/install.sh" ;;
  update) run bash "$STACK_DIR/scripts/update.sh" ;;
  backup) run bash "$STACK_DIR/scripts/backup.sh" ;;
  status) cmd_status ;;
  start) cmd_stack up -d ;;
  stop) cmd_stack stop ;;
  "") usage ;;
  *) echo "未知子命令: $SUB" >&2; usage; exit 1 ;;
esac
