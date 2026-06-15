# ==========================
# 运行阶段：Nginx + 工具环境
# 哪吒面板二进制由 entrypoint.sh 在容器启动时下载（支持 DASHBOARD_VERSION 锁版本）
# ==========================
FROM nginx:alpine

# 安装依赖（ca-certificates 替代原先从 nezha 镜像复制的 SSL 证书）
RUN apk add --no-cache \
    ca-certificates \
    wget \
    unzip \
    bash \
    curl \
    git \
    tar \
    openssl \
    jq \
    procps \
    tzdata \
    zip \
    sqlite \
    sqlite-libs

# 复制 cloudflared
COPY --from=cloudflare/cloudflared:latest /usr/local/bin/cloudflared /usr/local/bin/cloudflared

# Nginx 配置（main.conf 由 entrypoint 用 envsubst 渲染，支持 CF 注入的 $PORT）
COPY main.conf.template /etc/nginx/main.conf.template
RUN rm -f /etc/nginx/conf.d/default.conf
COPY ssl.conf.template /etc/nginx/ssl.conf.template

# 保证 nginx 运行时目录可写（CF 容器可能以非 root 运行）
RUN chmod -R 777 /etc/nginx/conf.d /var/cache/nginx /var/log/nginx \
    && touch /var/run/nginx.pid && chmod 666 /var/run/nginx.pid

# 时区
ENV TZ=Asia/Shanghai

# 工作目录
WORKDIR /dashboard

# 数据目录并设置权限（哪吒面板 app 由 entrypoint.sh 启动时下载到 /dashboard/app）
RUN mkdir -p /dashboard/data && chmod -R 777 /dashboard

# 暴露端口（CF 实际通过 $PORT 注入，此处仅为表意）
EXPOSE 8080

# 环境变量
ENV ARGO_DOMAIN="" \
    ARGO_AUTH="" \
    GH_TOKEN="" \
    GH_REPO_OWNER="" \
    GH_REPO_NAME="" \
    GH_BRANCH="" \
    ZIP_PASSWORD="" \
    GH_CLIENTID="" \
    GH_CLIENTSECRET="" \
    NZ_CLIENT_SECRET="" \
    NZ_UUID="" \
    NZ_TLS="" \
    AGENT_VERSION="" \
    DASHBOARD_VERSION="" \
    KEEP_BACKUPS="" \
    BACKUP_HOUR=""

# 复制脚本和静态文件
COPY restore.sh /restore.sh
COPY backup.sh /backup.sh
COPY entrypoint.sh /entrypoint.sh
COPY index.html /usr/share/nginx/html/index.html

# 设置可执行权限
RUN chmod +x /restore.sh /backup.sh /entrypoint.sh

# 启动脚本
CMD ["/entrypoint.sh"]
