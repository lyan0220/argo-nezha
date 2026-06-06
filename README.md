# ⭐ 哪吒面板 V1 · SAP Cloud Foundry 部署方案

> **安全提示**：本方案未使用 OAuth 登录，**首次登录后必须立即修改默认密码**。

- **SAP Cloud Foundry**（推荐）：通过 GitHub Actions 一键部署到任意 SAP CF 区域

---

## 🏗️ 架构

```
┌──────────────────────────────────────────────────────────────────┐
│                         容器内部                                  │
│                                                                   │
│   ┌─────────────┐   $PORT       ┌──────────────────┐             │
│   │ CF gorouter │ ────────────▶ │ nginx (main.conf)│ → index.html │
│   │             │   /health     │                  │   /health    │
│   └─────────────┘               └──────────────────┘              │
│                                                                   │
│   ┌──────────────────┐  443    ┌──────────────┐  8443   ┌──────┐  │
│   │ Cloudflare Edge  │ ──out─▶ │ cloudflared  │ ──────▶ │      │  │
│   │ (ARGO_DOMAIN)    │ tunnel  │              │  TLS    │nginx │  │
│   └──────────────────┘         └──────────────┘         │ ssl  │  │
│                                                          └──┬───┘  │
│                                                  8008       │      │
│                                            ┌─────────────◀──┘      │
│                                            │  哪吒面板 (app)        │
│                                            └─────────────┐          │
│                                                          │          │
│   ┌──────────────────┐                                   │          │
│   │  nezha-agent     │ ──── 探针上报到 ARGO_DOMAIN:443 ──┘          │
│   │  (容器内)        │                                              │
│   └──────────────────┘                                              │
└──────────────────────────────────────────────────────────────────┘
```

**两条独立的入口**：

- 平台分配的 URL（`$PORT`）→ 伪装页 + 健康检查
- Cloudflare Tunnel（`ARGO_DOMAIN`）→ 真实的哪吒面板

---

## 📋 环境变量

| 变量名              | 示例值              | 必填 | 说明                                                                    |
| ------------------- | ------------------- | ---- | ----------------------------------------------------------------------- |
| `ARGO_AUTH`         | `eyJhIjoi.......`   | ✅   | Cloudflare Tunnel Token                                                 |
| `ARGO_DOMAIN`       | `nezha.example.com` | ✅   | 面板访问域名，同时用于探针上报                                          |
| `NZ_UUID`           | `f8ff434...62e0`    | ✅   | 探针 UUID，[uuidgenerator.net](https://www.uuidgenerator.net/) 在线生成 |
| `GH_TOKEN`          | `ghp_xxxxxxxx`      | ✅   | GitHub PAT，用于配置自动备份                                            |
| `GH_REPO_OWNER`     | `your_username`     | ✅   | 备份仓库所有者                                                          |
| `GH_REPO_NAME`      | `nezha-backup`      | ✅   | 备份仓库名                                                              |
| `GH_BRANCH`         | `main`              | ✅   | 备份分支                                                                |
| `ZIP_PASSWORD`      | `change-me`         | ✅   | 备份压缩包密码                                                          |
| `NZ_CLIENT_SECRET`  | `kDerKi...mvj0XMy`  | ❌   | 留空自动生成（备份恢复后会保留旧值）                                    |
| `NZ_TLS`            | `true`              | ❌   | 探针 TLS 开关，默认 `true`                                              |
| `DASHBOARD_VERSION` | `v1.14.1`           | ❌   | 探针版本，默认 `latest`                                                 |
| `PORT`              | 由平台注入          | -    | CF 自动注入；本地默认 8080                                              |

---

## 🔧 Cloudflare Tunnel 配置

1. **开启 gRPC**：Cloudflare 控制台 → Network → 启用 gRPC
2. **创建 Tunnel** 并获取 Token（即 `ARGO_AUTH`）
3. **Public Hostname** 配置：

| 配置项 | 值                       |
| ------ | ------------------------ |
| Type   | `HTTPS`                  |
| URL    | `https://localhost:8443` |

**TLS 设置**：

- ✅ `No TLS Verify`
- ✅ `HTTP2 connection`

> ⚠️ URL 必须是 `localhost:8443`，不是 443。这是 SAP CF 非 root 容器的硬约束 —— 详见架构图里 cloudflared → nginx 的端口约定。

---

## 🚀 SAP Cloud Foundry 部署（推荐）

### 1. Fork 本仓库

### 2. 构建镜像

进入 **Actions** → 启用 workflows → 运行 **🐳 构建自己的镜像吧**：

- 镜像名：`argo-nezha`（保持默认）
- 标签：`latest`

构建完成后镜像地址为 `ghcr.io/<你的用户名>/argo-nezha:latest`。

> 如果是私有 GHCR 包，请到 **Packages** 页面把可见性改成 public，否则 SAP CF 拉不到镜像。

### 3. 配置 Secrets

在仓库 **Settings → Secrets and variables → Actions** 添加：

| Secret                                                         | 必填 | 说明                                           |
| -------------------------------------------------------------- | ---- | ---------------------------------------------- |
| `EMAIL` / `PASSWORD`                                           | ✅   | SAP BTP 账号                                   |
| `ARGO_DOMAIN` / `ARGO_AUTH` / `NZ_UUID`                        | ✅   | 面板与隧道                                     |
| `GH_TOKEN` / `GH_REPO_OWNER` / `GH_REPO_NAME` / `ZIP_PASSWORD` | ✅   | 备份配置                                       |
| `GH_BRANCH`                                                    | ⭕   | 默认 `main`                                    |
| `DOCKER_IMAGE`                                                 | ⭕   | 不填则使用 `ghcr.io/<owner>/argo-nezha:latest` |
| `MEMORY` / `DISK`                                              | ⭕   | 默认 `512M` / `1024M`                          |
| `NZ_CLIENT_SECRET` / `NZ_TLS` / `DASHBOARD_VERSION`            | ⭕   | 见上表                                         |

### 4. 触发部署

进入 **Actions → 自动部署 nezha 面板到 SAP**：

- 选择目标区域（如 `US(free)`）
- 应用名留空则自动生成

工作流会自动执行：登录 CF → 选择第一个 org/space → push 镜像 → 设置环境变量 → restage。

### 5. 访问面板

部署日志最后会输出：

```
伪装页 URL: https://<app-name>.cfapps.<region>.hana.ondemand.com
哪吒面板真实访问地址 = https://<ARGO_DOMAIN>
```

> 通过 `ARGO_DOMAIN` 访问哪吒面板。SAP 路由仅是伪装入口，不要直接访问。

---

## 💾 备份与恢复

### 自动备份

默认每天凌晨 4 点（北京时间）。`BACKUP_HOUR` 环境变量可改时段。

### 手动触发

1. 打开备份仓库的 `README.md`
2. 内容**全部替换**为单词 `backup`
3. 提交后等待最多 1 小时（守护进程每小时轮询一次）

### 自动恢复

容器启动时会自动从备份仓库拉取最新的 `data-*.zip` 解压恢复。无需手动操作。

---

## 📁 项目文件

```
.
├── .github/workflows/
│   ├── Packages.yml                        # 构建并推送镜像到 GHCR
│   └── 自动部署Nezha面板.yml                # 一键部署到 SAP CF
├── Dockerfile                              # 镜像定义
├── entrypoint.sh                           # 容器启动脚本
├── main.conf.template                      # nginx 主配置（监听 $PORT，envsubst 渲染）
├── ssl.conf.template                       # nginx SSL 配置（监听 8443）
├── manifest.yml                            # CF 部署描述（备用，工作流不依赖）
├── backup.sh                               # 备份脚本
├── restore.sh                              # 恢复脚本
├── index.html                              # 伪装页面（建议替换）
├── README.md                               # 本文档
└── 详细部署流程.md                          # 保姆级新手教程
```

| 文件                 | 用途                               | 备注                                                                 |
| -------------------- | ---------------------------------- | -------------------------------------------------------------------- |
| `main.conf.template` | 监听 `$PORT`，提供 `/health` 端点  | 启动时由 envsubst 渲染                                               |
| `ssl.conf.template`  | 监听 `8443`，承接 cloudflared 流量 | 8443 是非特权端口，避开 SAP CF 非 root 限制                          |
| `manifest.yml`       | CF 应用描述                        | 仅作参考，GitHub Actions 工作流通过 `cf push` 命令行参数完成同等配置 |
| `index.html`         | 伪装页                             | 建议用 AI 生成自定义内容，隐藏真实身份                               |

---

## 🔍 端口说明

| 端口               | 谁在用                                   | 公网          |
| ------------------ | ---------------------------------------- | ------------- |
| `$PORT`（CF 注入） | CF gorouter ↔ nginx（伪装页 + 健康检查） | ✅            |
| `8443`（容器内）   | cloudflared ↔ nginx SSL                  | ❌ 容器内回环 |
| `8008`（容器内）   | nginx ↔ 哪吒面板 app                     | ❌ 容器内回环 |
| `443`（CF 边缘）   | 用户 ↔ Cloudflare（即 `ARGO_DOMAIN`）    | ✅            |

> 容器内端口 `8443` 与 Cloudflare 边缘端口 `443` 是两层概念，互不影响。

---

## 🛟 常见问题

| 问题                                      | 解决办法                                                              |
| ----------------------------------------- | --------------------------------------------------------------------- |
| 部署失败：`bind() to 0.0.0.0:443 failed`  | 确认 `ssl.conf.template` 是 8443，未被改回 443                        |
| Cloudflare Tunnel 显示 connection refused | 检查 Tunnel 后台 URL 是 `https://localhost:8443`                      |
| 健康检查超时                              | 工作流已设置 `-t 180`；如仍超时检查 GHCR 镜像是否 public              |
| 探针离线                                  | 检查 Cloudflare 已开启 gRPC，且 TLS 设置勾选了 No TLS Verify          |
| 手动备份没触发                            | 备份仓库的 `README.md` 内容必须**仅有** `backup`（不含其他字符）      |
| 重启后数据丢失                            | 检查 `GH_TOKEN`/`GH_REPO_*` 是否正确，能否在备份仓库看到 `data-*.zip` |

---

## ⭐ 觉得有用就点个 Star 吧

_祝部署顺利！_ 🎉
