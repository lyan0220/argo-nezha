# ⭐ 哪吒面板 V1 · SAP Cloud Foundry 部署方案

> ⚠️ **安全提示**：本方案默认未启用 OAuth 登录，**首次登录后必须立即修改默认密码**（默认 `admin/admin`）。
>
> 如果在部署时提供 `GH_CLIENTID` 和 `GH_CLIENTSECRET`，入口脚本会在 `/dashboard/data/config.yaml` 中补写 GitHub OAuth 配置。

通过 GitHub Actions 一键部署到 SAP CF，使用 Cloudflare Tunnel 安全访问，每天自动备份到 GitHub。

**两条独立入口**

- 平台分配的 URL（`$PORT`）→ 伪装页 + 健康检查
- Cloudflare Tunnel（`ARGO_DOMAIN`）→ 真实的哪吒面板

---

## 一、准备工作

| 平台       | 用途                                          |
| ---------- | --------------------------------------------- |
| GitHub     | 存放代码、构建镜像、备份数据（Releases 附件） |
| Cloudflare | 提供域名和安全隧道                            |
| SAP BTP    | 运行容器（CF 免费区即可）                     |

### 1.1 创建 GitHub 备份仓库

新建一个 **Private** 仓库（如 `nezha-backup`），勾选 **Add a README file**。

> 备份数据以 Release 附件形式存储在固定标签 `latest` 下，不会写入仓库文件树，因此仓库体积始终保持轻量。

### 1.2 生成 GitHub Token

提供两种方式，任选其一：

#### 方式 A：Classic Token（简单，权限较宽）

**Settings → Developer settings → Personal access tokens → Tokens (classic) → Generate new token (classic)**：

- Expiration：**No expiration**
- 权限：
  - ✅ `repo`（**必选**，覆盖 Releases 附件上传与 README 更新）

> Token 格式：`ghp_xxxxxxxxxxxx`

#### 方式 B：Fine-grained Token（推荐，最小权限）

**Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**：

- **Resource owner**：选择你的账号
- **Repository access**：**Only select repositories** → 选择备份仓库（如 `nezha-backup`）
- **Permissions**：
  - ✅ **Contents**: Read and write（更新 README、操作 Releases 附件）
  - ✅ **Metadata**: Read（默认已勾选，基础 API 访问）

> Token 格式：`github_pat_xxxxxxxxxxxx`

---

> ⚠️ 两种 Token 只显示一次，立刻复制保存。Fine-grained Token 仅作用于指定仓库，泄露后影响范围更小。

### 1.3 注册 SAP BTP Cloud Foundry

注册 Trial 账号 → 创建 Subaccount 启用 Cloud Foundry → 创建 Space（任意名称）。记下登录邮箱和密码。工作流会自动选第一个 org/space，无需手动配置。

---

## 二、Fork 并构建镜像

1. **Fork** 本仓库到自己的账号
2. **Actions** → 启用 workflows → 运行 **Build and Push Docker Image**（默认镜像名 `argo-nezha`，标签 `latest`）
3. 构建完成后进入 **Packages → argo-nezha → Package settings**，将可见性改为 **Public**

> ⚠️ GHCR 包必须是 public，否则 SAP CF 拉不到镜像。

镜像地址：`ghcr.io/<你的用户名>/argo-nezha:latest`

---

## 三、配置 Cloudflare Tunnel

### 3.1 创建 Tunnel 并获取 Token

**Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared** → 复制 `eyJ` 开头的 Token，这就是 `ARGO_AUTH`。

### 3.2 配置 Public Hostname

| 配置项    | 值                       |
| --------- | ------------------------ |
| Subdomain | 自定义（如 `nezha`）     |
| Domain    | 选择你的域名             |
| Type      | `HTTPS`                  |
| URL       | `https://localhost:8443` |

展开 **TLS** 设置：

- ✅ `No TLS Verify`
- ✅ `HTTP2 connection`

> ⚠️ URL 必须是 `localhost:8443`，**不是 443**。SAP CF 容器以非 root 运行，无法监听 < 1024 端口。

完整域名（如 `nezha.example.com`）就是 `ARGO_DOMAIN`。

### 3.3 开启 gRPC

回到主面板 → 点击你的域名 → **Network** → 开启 **gRPC**。

---

## 四、（可选）配置 GitHub OAuth 登录

如果想启用 GitHub 账号登录哪吒面板，需要创建 GitHub OAuth App 并获取凭证。

### 4.1 创建 GitHub OAuth App

1. 登录 GitHub 账号 → 打开 **Settings → Developer settings → OAuth Apps → New OAuth App**
2. 填写应用信息：
   - **Application name**：任意名称，如 `Nezha Panel`
   - **Homepage URL**：`https://<ARGO_DOMAIN>`（你的面板域名）
   - **Authorization callback URL**：`https://<ARGO_DOMAIN>/api/v1/oauth2/callback`
   - **Application description**：可选

3. 点击 **Register application**
4. 记下 **Client ID**
5. 点击 **Generate a new client secret**，记下生成的 **Client Secret**（只显示一次）

> ⚠️ `Client Secret` 只显示一次，立刻复制保存。

### 4.2 启用 OAuth 登录

在部署时配置以下 Secrets（参考下一步"五、配置 GitHub Secrets"）：

- `GH_CLIENTID`：从步骤 4.1 复制的 Client ID
- `GH_CLIENTSECRET`：从步骤 4.1 复制的 Client Secret

> 如果同时提供这两个变量，容器启动时会自动在 `/dashboard/data/config.yaml` 中写入 GitHub OAuth 配置，面板登录页将显示 **GitHub 登录**按钮。

---

## 五、配置 GitHub Secrets

仓库 **Settings → Secrets and variables → Actions** 添加。

### 5.1 必填变量

| Secret          | 默认值 | 说明                                     |
| --------------- | ------ | ---------------------------------------- |
| `EMAIL`         | -      | SAP BTP 登录邮箱                         |
| `PASSWORD`      | -      | SAP BTP 登录密码                         |
| `ARGO_AUTH`     | -      | Cloudflare Tunnel Token（步骤 3.1）      |
| `ARGO_DOMAIN`   | -      | 面板域名（步骤 3.2），同时是探针上报地址 |
| `GH_TOKEN`      | -      | GitHub PAT（步骤 1.2）                   |
| `GH_REPO_OWNER` | -      | 备份仓库所有者                           |
| `GH_REPO_NAME`  | -      | 备份仓库名称                             |
| `ZIP_PASSWORD`  | -      | 备份压缩包密码（自定义任意字符串）       |

### 5.2 可选变量

| Secret             | 默认值                              | 说明                                                                                 |
| ------------------ | ----------------------------------- | ------------------------------------------------------------------------------------ |
| `GH_CLIENTID`      | -                                   | GitHub OAuth App 的 Client ID，用于启用 GitHub 登录（需同时提供 `GH_CLIENTSECRET`）  |
| `GH_CLIENTSECRET`  | -                                   | GitHub OAuth App 的 Client Secret，用于启用 GitHub 登录（需同时提供 `GH_CLIENTID`）  |
| `NZ_UUID`          | -                                   | 设置则强制用此 UUID 安装容器内探针（覆盖备份）；全新部署需要时填                     |
| `NZ_CLIENT_SECRET` | 自动生成 / 备份值                   | 首次部署留空 → 随机生成；恢复部署留空 → 沿用备份值；显式设置 → 覆盖面板与探针 secret |
| `NZ_TLS`           | `true`                              | 探针 TLS 开关                                                                        |
| `AGENT_VERSION`    | `latest`                            | 探针版本（`nezhahq/agent` 仓库的 tag）                                               |
| `BACKUP_HOUR`      | `4`                                 | 自动备份时段（北京时间，0-23）                                                       |
| `KEEP_BACKUPS`     | `5`                                 | Release 中保留的备份附件数量，超出自动删除最旧的                                     |
| `GH_BRANCH`        | `main`                              | 备份仓库 README 所在分支                                                             |
| `DOCKER_IMAGE`     | `ghcr.io/<owner>/argo-nezha:latest` | 自定义镜像地址                                                                       |
| `MEMORY`           | `512M`                              | CF 内存配额                                                                          |
| `DISK`             | `1024M`                             | CF 磁盘配额                                                                          |

> **提示**：`GH_CLIENTID` 和 `GH_CLIENTSECRET` 必须同时提供，容器启动时会补写或覆盖 `/dashboard/data/config.yaml` 中的 `oauth2` 配置节点；否则继续保持当前非 OAuth 登录逻辑。

---

## 六、部署到 SAP CF

**Actions → 自动部署 nezha 面板到 SAP → Run workflow**：

- **region**：推荐 `US(free)` 或 `SG(free)`
- **app_name**：留空自动生成

工作流会自动执行：登录 CF → 选择第一个 org/space → `cf push` → 设置环境变量 → `cf restage`。

部署日志末尾输出：

```
伪装页 URL: https://<app-name>.cfapps.<region>.hana.ondemand.com
哪吒面板真实访问地址 = https://<ARGO_DOMAIN>
```

> 通过 `ARGO_DOMAIN` 访问哪吒面板。SAP 路由仅是伪装入口，不要直接访问。

---

## 七、首次登录

1. 打开 `https://<ARGO_DOMAIN>`，使用 `admin / admin` 登录
2. **立即修改密码**

---

## 八、备份与恢复

备份采用 **GitHub Releases Assets** 方案：备份文件以二进制附件上传到备份仓库的 `latest` Release 下，不占用 git 历史，单文件最大支持 2GB。

### 自动备份

- 默认每天凌晨 4 点（北京时间）自动执行，文件名 `data-YYYY-MM-DD-HHMMSS.zip`
- 仅保留最近 5 份备份（可通过 `KEEP_BACKUPS` 调整），超出自动删除旧附件

### 手动触发

- 把备份仓库的 `README.md` 内容**全部替换**为单词 `backup`，提交后等待最多 1 小时

> 手动触发的 `README.md` 内容必须**只有** `backup` 6 个字符，不含空格/换行/其他字符。

### 自动恢复

- 容器启动时自动从 `latest` Release 下载最新的 `data-*.zip` 附件并解压恢复，无需手动操作
- 也支持指定文件名恢复历史版本：`/restore.sh data-2025-01-01-040000.zip`

### 备份内容

```
data-YYYY-MM-DD-HHMMSS.zip
├── data/         面板数据目录（sqlite.db、config.yaml 等）
└── config.yml    探针配置（如存在；含 client_secret 与 uuid）
```

> 备份包含探针配置后，恢复时容器内探针 `uuid` 不会漂移，面板不会把它当成新机器重复添加；`NZ_UUID` 仅在**全新部署**或想**强制重置探针 UUID**时填写（设置后会覆盖备份中的探针配置）。

### 备份方案技术特点

| 特性        | 说明                                              |
| ----------- | ------------------------------------------------- |
| 存储位置    | GitHub Releases Assets（固定 `latest` 标签）      |
| 上传方式    | 二进制直传（`--data-binary`），无 base64 编码开销 |
| 大小限制    | 单文件 2GB（旧 Contents API 方案仅 100MB）        |
| 仓库体积    | 不膨胀 git 历史，仓库始终轻量                     |
| SQLite 安全 | 使用 `.backup` 命令生成一致性快照                 |
| 历史清理    | 备份前自动清理 30 天前的监控/流量记录并 VACUUM    |

---

## 九、架构与端口

| 端口               | 谁在用                                   | 公网          |
| ------------------ | ---------------------------------------- | ------------- |
| `$PORT`（CF 注入） | CF gorouter ↔ nginx（伪装页 + 健康检查） | ✅            |
| `8443`（容器内）   | cloudflared ↔ nginx SSL                  | ❌ 容器内回环 |
| `8008`（容器内）   | nginx ↔ 哪吒面板 app                     | ❌ 容器内回环 |
| `443`（CF 边缘）   | 用户 ↔ Cloudflare（即 `ARGO_DOMAIN`）    | ✅            |

> 容器内端口 `8443` 与 Cloudflare 边缘端口 `443` 是两层概念，互不影响。

---

## 十、项目文件

```
.
├── .github/workflows/
│   ├── build.yml                      # 构建并推送镜像到 GHCR
│   └── 自动部署Nezha面板.yml           # 一键部署到 SAP CF
├── Dockerfile                         # 镜像定义
├── entrypoint.sh                      # 容器启动脚本
├── main.conf.template                 # nginx 主配置（监听 $PORT，envsubst 渲染）
├── ssl.conf.template                  # nginx SSL 配置（监听 8443）
├── manifest.yml                       # CF 部署描述（备用，工作流不依赖）
├── backup.sh / restore.sh             # 备份与恢复脚本
├── index.html                         # 伪装页面（建议替换）
└── README.md                          # 本文档
```

> `index.html` 建议用 AI 生成自定义内容。

---

## 十一、常见问题

| 问题                                          | 解决办法                                                                    |
| --------------------------------------------- | --------------------------------------------------------------------------- |
| `cf push` 报 image not found                  | GHCR 镜像没改 public（见步骤二）                                            |
| 部署失败：`bind() to 0.0.0.0:443 failed`      | `ssl.conf.template` 被改回 443，应保持 8443                                 |
| Cloudflare Tunnel 显示 502/connection refused | Tunnel URL 必须是 `https://localhost:8443`                                  |
| 健康检查超时                                  | 工作流已设 `-t 180`；首次拉镜像稍慢，仍超时则检查 GHCR 镜像可见性           |
| 面板打开但探针离线                            | Cloudflare 网络未开启 gRPC，或 Tunnel TLS 未勾选 No TLS Verify              |
| 全新部署后服务器列表无容器内探针              | `NZ_UUID` 未设置（全新部署需要；从备份恢复时不需要）                        |
| 手动备份没触发                                | `README.md` 内容必须**仅有** `backup`（不含其他字符）                       |
| 重启后数据丢失                                | 检查 `GH_TOKEN` / `GH_REPO_*`，确认备份仓库 Releases 中有 `data-*.zip` 附件 |
| 工作流报名称冲突                              | 改用自定义 `app_name`，或等几分钟让旧应用清理                               |

---

## 🔑 三个关键点

1. **GHCR 镜像必须是 public**
2. **Cloudflare Tunnel URL 必须是 `https://localhost:8443`**
3. **首次登录立即改密码**

_祝部署顺利！_ 🎉
