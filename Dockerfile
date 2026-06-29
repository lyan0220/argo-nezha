FROM nginx:alpine

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

COPY main.conf.template /etc/nginx/main.conf.template
RUN rm -f /etc/nginx/conf.d/default.conf
COPY ssl.conf.template /etc/nginx/ssl.conf.template

RUN chmod -R 777 /etc/nginx/conf.d /var/cache/nginx /var/log/nginx \
    && touch /var/run/nginx.pid && chmod 666 /var/run/nginx.pid

ENV TZ=Asia/Shanghai
WORKDIR /dashboard
RUN mkdir -p /dashboard/data && chmod -R 777 /dashboard

EXPOSE 8080

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

COPY restore.sh /restore.sh
COPY backup.sh /backup.sh
COPY entrypoint.sh /entrypoint.sh
COPY index.html /usr/share/nginx/html/index.html

RUN chmod +x /restore.sh /backup.sh /entrypoint.sh

CMD ["/entrypoint.sh"]
