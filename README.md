# ⭐ 哪吒面板 V1 · SAP Cloud Foundry 部署方案

> ⚠️ **安全提示**：本方案未使用 OAuth 登录，**首次登录后必须立即修改默认密码**（默认 `admin/admin`）。

通过 GitHub Actions 一键部署到 SAP CF，使用 Cloudflare Tunnel 安全访问，每天自动备份到 GitHub。

**两条独立入口**

- 平台分配的 URL（`$PORT`）→ 伪装页 + 健康检查
- Cloudflare Tunnel（`ARGO_DOMAIN`）→ 真实的哪吒面板

---

## 一、准备工作

| 平台       | 用途                         |
| ---------- | ---------------------------- |
| GitHub     | 存放代码、构建镜像、备份数据 |
| Cloudflare | 提供域名和安全隧道           |
| SAP BTP    | 运行容器（CF 免费区即可）    |

### 1.1 创建 GitHub 备份仓库

新建一个 **Private** 仓库（如 `nezha-backup`），勾选 **Add a README file**。

### 1.2 生成 GitHub Token

**Settings → Developer settings → Personal access tokens → Tokens (classic) → Generate new token (classic)**：

- Expiration：**No expiration**
- 权限：
  - ✅ `repo`（**必选**，备份脚本读写备份仓库需要）

> Token 只显示一次，立刻复制保存。格式：`ghp_xxxxxxxxxxxx`

### 1.3 注册 SAP BTP Cloud Foundry

注册 Trial 账号 → 创建 Subaccount 启用 Cloud Foundry → 创建 Space（任意名称）。记下登录邮箱和密码。工作流会自动选第一个 org/space，无需手动配置。

---

## 二、Fork 并构建镜像

1. **Fork** 本仓库到自己的账号
2. **Actions** → 启用 workflows → 运行 **🐳 构建自己的镜像吧**（镜像名 `argo-nezha`，标签 `latest`）
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

## 四、配置 GitHub Secrets

仓库 **Settings → Secrets and variables → Actions** 添加：

### 必填

| Secret          | 说明                                                                |
| --------------- | ------------------------------------------------------------------- |
| `EMAIL`         | SAP BTP 登录邮箱                                                    |
| `PASSWORD`      | SAP BTP 登录密码                                                    |
| `ARGO_AUTH`     | Cloudflare Tunnel Token（步骤 3.1）                                 |
| `ARGO_DOMAIN`   | 面板域名（步骤 3.2），同时用于探针上报                              |
| `NZ_UUID`       | 探针 UUID，[uuidgenerator.net](https://www.uuidgenerator.net/) 生成 |
| `GH_TOKEN`      | GitHub PAT（步骤 1.2）                                              |
| `GH_REPO_OWNER` | 备份仓库所有者                                                      |
| `GH_REPO_NAME`  | 备份仓库名称                                                        |
| `ZIP_PASSWORD`  | 备份压缩包密码（自定义任意字符串）                                  |

### 可选

| Secret              | 默认值                              | 说明                         |
| ------------------- | ----------------------------------- | ---------------------------- |
| `GH_BRANCH`         | `main`                              | 备份分支                     |
| `DOCKER_IMAGE`      | `ghcr.io/<owner>/argo-nezha:latest` | 自定义镜像地址               |
| `MEMORY`            | `512M`                              | CF 内存配额                  |
| `DISK`              | `1024M`                             | CF 磁盘配额                  |
| `NZ_CLIENT_SECRET`  | 自动生成                            | 留空即可，恢复备份后保留旧值 |
| `NZ_TLS`            | `true`                              | 探针 TLS 开关                |
| `DASHBOARD_VERSION` | `latest`                            | 探针版本                     |
| `BACKUP_HOUR`       | `4`                                 | 自动备份时段（北京时间）     |

---

## 五、部署到 SAP CF

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

## 六、首次登录

1. 打开 `https://<ARGO_DOMAIN>`，使用 `admin / admin` 登录
2. **立即修改密码**

---

## 七、备份与恢复

- **自动备份**：默认每天凌晨 4 点（北京时间），文件名 `data-YYYY-MM-DD-HHMMSS.zip`
- **手动触发**：把备份仓库的 `README.md` 内容**全部替换**为单词 `backup`，提交后等待最多 1 小时
- **自动恢复**：容器启动时自动拉取最新备份解压恢复，无需手动操作

> 手动触发的 `README.md` 内容必须**只有** `backup` 6 个字符，不含空格/换行/其他字符。

---

## 八、架构与端口

| 端口               | 谁在用                                   | 公网          |
| ------------------ | ---------------------------------------- | ------------- |
| `$PORT`（CF 注入） | CF gorouter ↔ nginx（伪装页 + 健康检查） | ✅            |
| `8443`（容器内）   | cloudflared ↔ nginx SSL                  | ❌ 容器内回环 |
| `8008`（容器内）   | nginx ↔ 哪吒面板 app                     | ❌ 容器内回环 |
| `443`（CF 边缘）   | 用户 ↔ Cloudflare（即 `ARGO_DOMAIN`）    | ✅            |

> 容器内端口 `8443` 与 Cloudflare 边缘端口 `443` 是两层概念，互不影响。

---

## 九、项目文件

```
.
├── .github/workflows/
│   ├── Packages.yml                   # 构建并推送镜像到 GHCR
│   └── 自动部署Nezha面板.yml          # 一键部署到 SAP CF
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

## 十、常见问题

| 问题                                          | 解决办法                                                          |
| --------------------------------------------- | ----------------------------------------------------------------- |
| `cf push` 报 image not found                  | GHCR 镜像没改 public（见步骤二）                                  |
| 部署失败：`bind() to 0.0.0.0:443 failed`      | `ssl.conf.template` 被改回 443，应保持 8443                       |
| Cloudflare Tunnel 显示 502/connection refused | Tunnel URL 必须是 `https://localhost:8443`                        |
| 健康检查超时                                  | 工作流已设 `-t 180`；首次拉镜像稍慢，仍超时则检查 GHCR 镜像可见性 |
| 面板打开但探针离线                            | Cloudflare 网络未开启 gRPC，或 Tunnel TLS 未勾选 No TLS Verify    |
| 手动备份没触发                                | `README.md` 内容必须**仅有** `backup`（不含其他字符）             |
| 重启后数据丢失                                | 检查 `GH_TOKEN` / `GH_REPO_*`，确认备份仓库有 `data-*.zip`        |
| 工作流报名称冲突                              | 改用自定义 `app_name`，或等几分钟让旧应用清理                     |

---

## 🔑 三个关键点

1. **GHCR 镜像必须是 public**
2. **Cloudflare Tunnel URL 必须是 `https://localhost:8443`**
3. **首次登录立即改密码**

_祝部署顺利！_ 🎉
