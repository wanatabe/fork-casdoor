# 部署手册（离线路线）

SSO（casdoor fork）采用**路线 A：内网离线部署**。目标服务器无法访问镜像仓库，
镜像在外网构建机导出为 tar，经物理介质（scp / U 盘）进入内网后 `docker load`。

**不使用 CI/CD**：所有构建在本机完成，交付物是 `deploy/images/` 下的镜像 tar。

## 目录结构

```
deploy/
├── sso                    # 统一入口（转发到 scripts/sso.sh）
├── scripts/sso.sh         # CLI 实现
├── images/                # 导出的镜像 tar（gitignore）
└── casdoor/               # 业务栈
    ├── docker-compose.yml # casdoor + mysql
    ├── casdoor.local.env  # 非敏感参数：版本号、端口、镜像名（入库）
    ├── .env               # 敏感口令（gitignore，从 .env.example 复制）
    ├── conf/app.conf      # 生产配置（gitignore，从 app.conf.example 复制）
    ├── scripts/           # install / update / backup
    └── backup/            # 数据库备份（gitignore）
```

## 一、镜像构建与发版（构建机，有外网）

前置：Docker（含 buildx）、能访问 Docker Hub / Go proxy 拉取基础镜像
（node:20.20.1、golang:1.25.8、alpine、mysql:8.0.25）。

```bash
bash deploy/sso release        # 构建 → 写回版本号 → 导出当前版本镜像 tar
bash deploy/sso release --all  # 需要备多套版本时，导出全部本地 tag
```

- **Dockerfile**：仓库根目录的 `Dockerfile`，构建 target 为 `STANDARD`
  （Alpine 运行镜像，与上游官方 `casbin/casdoor` 一致）。
- **版本规则（单一来源）**：改根目录 `VERSION` 文件 → 跑 `release`。
  镜像 tag = `<VERSION>-<git sha>`（工作区有未提交改动时带 `-dirty` 后缀），
  `release` 会把新 tag 自动写回 `deploy/casdoor/casdoor.local.env`。
  **提交代码前先把这个写回一起提交**，保证部署机拿到的版本号与镜像对应。
- **导出规则**：默认只导出当前版本 + mysql（回滚场景见下）；
  `deploy/images/` 会被自动清理过时 tar；`--all` 才全量导出。
- 旋钮：`IMAGES_DIR=...` 改导出目录，`PRUNE_STALE_TARS=0` 关闭清理。

## 二、首次部署（内网服务器）

前置：服务器已装 Docker 与 compose 插件（或 docker-compose）。

```bash
# 1. 传输：把仓库的 deploy/ 目录和 images/ 一起传上去
scp -r deploy/ user@server:/opt/sso/

# 2. 准备口令与配置（两个文件里的 MySQL 口令必须一致）
cd /opt/sso
cp deploy/casdoor/.env.example deploy/casdoor/.env          # 改 MYSQL_ROOT_PASSWORD
cp deploy/casdoor/conf/app.conf.example deploy/casdoor/conf/app.conf
#   ↑ 修改 dataSourceName 中的口令；按需改 origin、defaultLanguage 等

# 3. 导入镜像并起栈
bash deploy/sso images load
bash deploy/sso install
```

安装完成访问 `http://<服务器>:8000`，默认账号 `admin / 123`，**登录后立即改密**。

## 三、日常更新与回滚

```bash
# 更新：同步最新 deploy/（含新写回的版本号）+ 新镜像 tar 后
bash deploy/sso update        # 导入镜像 → 自动备份数据库 → up -d

# 回滚：把 casdoor.local.env 的 CASDOOR_VERSION 改回上一版（对应 tar 放回 images/）
bash deploy/sso update

# 状态
bash deploy/sso status
```

## 四、端口、网络与重启策略

| 项 | 值 |
|---|---|
| 对外端口 | `${CASDOOR_PORT:-8000}` → 容器 8000（唯一入口，防火墙只需放行它） |
| MySQL | 仅栈内网络 `internal` 可达，**不映射宿主端口** |
| casdoor 重启策略 | `on-failure:1`（反复崩溃即停住报警，不无限重启掩盖问题） |
| mysql 重启策略 | `unless-stopped` |
| 健康检查 | casdoor: `GET /api/health`；mysql: `mysqladmin ping` |
| 数据持久化 | named volume `mysql-data`（数据库）、`casdoor-logs`（日志）；配置走 `./conf` 挂载 |

## 五、备份策略

- `update` 前自动 `mysqldump --single-transaction` 到 `deploy/casdoor/backup/`，
  保留最近 `BACKUP_KEEP`（默认 10）份；手动备份：`bash deploy/sso backup`。
- 建议定期把 `backup/` 与 `conf/` 异地再备一份。

## 六、数据库结构说明（无独立迁移框架）

casdoor 使用 ORM 在启动时自动建表/加列（`--createDatabase=true` 同时自动建库），
因此本目录**没有** Flyway 式的 V/U 迁移脚本。注意：

- 升级是"自动前向迁移"，**回滚版本不会自动回滚表结构**；
- 跨大版本升级前务必先 `bash deploy/sso backup` 确认备份可用再 update。

## 七、口令同步提醒（重要）

MySQL root 口令存在于两处，修改时必须同时改：

1. `deploy/casdoor/.env` 的 `MYSQL_ROOT_PASSWORD`（mysql 容器初始化与备份用）
2. `deploy/casdoor/conf/app.conf` 的 `dataSourceName`（casdoor 连接用）

两个文件均已 gitignore，真实口令不入库。

## 八、脚本跨平台

所有脚本 `#!/usr/bin/env bash`，只用 POSIX 通用特性，Windows（Git Bash）、
macOS、Linux 均可执行；`.gitattributes` 已保证 `*.sh` 以 LF 入库。
任何操作前可加 `--dry-run` 先看将执行的命令，例如：

```bash
bash deploy/sso release --dry-run
bash deploy/sso install --dry-run
```
