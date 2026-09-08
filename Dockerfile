FROM nginx:1.31.2-alpine

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

RUN chmod -R 777 /etc/nginx/conf.d /var/log/nginx \
    && mkdir -p /tmp/nginx \
    && chmod 777 /tmp/nginx

ENV TZ=Asia/Shanghai
WORKDIR /dashboard
RUN mkdir -p /dashboard/data && chmod -R 777 /dashboard

EXPOSE 8080

COPY restore.sh /restore.sh
COPY backup.sh /backup.sh
COPY entrypoint.sh /entrypoint.sh
COPY index.html /usr/share/nginx/html/index.html

RUN chmod +x /restore.sh /backup.sh /entrypoint.sh

CMD ["/entrypoint.sh"]
