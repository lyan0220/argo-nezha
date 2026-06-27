# 哪吒面板 V1 · Hugging Face 部署方案

> **安全提示**：首次登录后立即修改默认密码（默认 `admin/admin`）。
> 提供 `GH_CLIENTID` + `GH_CLIENTSECRET` 可自动启用 GitHub OAuth 登录。

通过 Hugging Face Spaces (Docker) 运行哪吒面板，Cloudflare Tunnel 提供安全访问，GitHub Releases 自动备份。

---

## 一、准备工作

| 平台         | 用途                           |
| ------------ | ------------------------------ |
| Hugging Face | 运行 Docker 容器               |
| GitHub       | 存放代码、备份数据（Releases） |
| Cloudflare   | 域名 + 安全隧道                |

### 1.1 创建 GitHub 备份仓库

新建 **Private** 仓库（如 `nezha-backup`），勾选 **Add a README file**。

### 1.2 生成 GitHub Token

**Settings → Developer settings → Personal access tokens → Fine-grained tokens**：

- **Repository access**：仅选备份仓库
- **Permissions**：Contents (Read and write) + Metadata (Read)

---

## 二、配置 Cloudflare Tunnel

### 2.1 创建 Tunnel

**Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared** → 复制 `eyJ` 开头的 Token（即 `ARGO_AUTH`）。

### 2.2 配置 Public Hostname

| 配置项    | 值                       |
| --------- | ------------------------ |
| Subdomain | 自定义（如 `nezha`）     |
| Domain    | 选择你的域名             |
| Type      | `HTTPS`                  |
| URL       | `https://localhost:8443` |

展开 **TLS**：勾选 `No TLS Verify` + `HTTP2 connection`

### 2.3 开启 gRPC

域名 → **Network** → 开启 **gRPC**。

---

## 三、部署到 Hugging Face

1. Fork 本仓库
2. 进入 [Hugging Face Spaces](https://huggingface.co/spaces)，点击 **Create new Space**
3. 选择 **Docker**，关联你 Fork 的仓库
4. 在 Space 的 **Settings → Variables and secrets** 中添加环境变量（见下方表格）

### 必填变量

| 变量            | 说明                               |
| --------------- | ---------------------------------- |
| `ARGO_AUTH`     | Cloudflare Tunnel Token            |
| `ARGO_DOMAIN`   | 面板域名（如 `nezha.example.com`） |
| `GH_TOKEN`      | GitHub PAT                         |
| `GH_REPO_OWNER` | 备份仓库所有者                     |
| `GH_REPO_NAME`  | 备份仓库名称                       |
| `ZIP_PASSWORD`  | 备份压缩包密码                     |

### 可选变量

| 变量                | 默认值   | 说明                                              |
| ------------------- | -------- | ------------------------------------------------- |
| `GH_CLIENTID`       | -        | GitHub OAuth Client ID（需同时提供 CLIENTSECRET） |
| `GH_CLIENTSECRET`   | -        | GitHub OAuth Client Secret                        |
| `NZ_UUID`           | -        | 强制指定容器内探针 UUID（全新部署时填写）         |
| `NZ_CLIENT_SECRET`  | 自动生成 | 面板与探针通信密钥                                |
| `NZ_TLS`            | `true`   | 探针 TLS 开关                                     |
| `AGENT_VERSION`     | `latest` | 探针版本                                          |
| `DASHBOARD_VERSION` | `latest` | 面板版本（如 `v1.1.1`），启动时自动下载           |
| `BACKUP_HOUR`       | `4`      | 自动备份时段（北京时间 0-23）                     |
| `KEEP_BACKUPS`      | `5`      | 保留备份数量                                      |

---

## 四、首次登录

打开 `https://<ARGO_DOMAIN>`，使用 `admin / admin` 登录，**立即修改密码**。

---

## 五、备份与恢复

备份文件以 Release 附件存储在备份仓库的 `latest` 标签下。

- **自动备份**：每天凌晨 4 点（可调），保留最近 5 份
- **手动触发**：将备份仓库 `README.md` 内容替换为 `backup`
- **自动恢复**：容器启动时自动下载最新备份

---

## 六、架构与端口

| 端口   | 用途                              | 公网 |
| ------ | --------------------------------- | ---- |
| `7860` | HF 健康检查（伪装页）             | 是   |
| `8443` | cloudflared ↔ nginx SSL（容器内） | 否   |
| `8008` | nginx ↔ 哪吒面板（容器内）        | 否   |

访问路径：用户 → Cloudflare 443 → Argo Tunnel → 容器内 nginx:8443 → 面板:8008

---

## 七、常见问题

| 问题                            | 解决                                                       |
| ------------------------------- | ---------------------------------------------------------- |
| Tunnel 502 / connection refused | Tunnel URL 必须是 `https://localhost:443`                  |
| 探针离线                        | Cloudflare 域名需开启 gRPC + Tunnel TLS 勾选 No TLS Verify |
| 全新部署无容器内探针            | 需设置 `NZ_UUID`                                           |
| 重启后数据丢失                  | 检查备份变量是否完整配置                                   |

---

**关键三点**：Tunnel URL 必须是 `https://localhost:8443`　|　Cloudflare 域名开启 gRPC　|　首次登录改密码
