#!/bin/sh

ARGO_DOMAIN=${ARGO_DOMAIN:-""}
ARGO_AUTH=${ARGO_AUTH:-""}
NZ_UUID=${NZ_UUID:-""}
NZ_CLIENT_SECRET=${NZ_CLIENT_SECRET:-""}
NZ_TLS=${NZ_TLS:-true}
AGENT_VERSION=${AGENT_VERSION:-latest}
DASHBOARD_VERSION=${DASHBOARD_VERSION:-latest}

GH_REPO_OWNER=${GH_REPO_OWNER:-""}
GH_REPO_NAME=${GH_REPO_NAME:-""}
GH_TOKEN=${GH_TOKEN:-""}
GH_BRANCH=${GH_BRANCH:-main}
ZIP_PASSWORD=${ZIP_PASSWORD:-""}

PORT=${PORT:-7860}
export PORT

log_info()  { echo "[I] $(date '+%H:%M:%S') $1"; }
log_ok()    { echo "[+] $(date '+%H:%M:%S') $1"; }
log_warn()  { echo "[W] $(date '+%H:%M:%S') $1"; }
log_error() { echo "[E] $(date '+%H:%M:%S') $1"; }

wait_for_port() {
    local port=$1
    local max_wait=${2:-60}
    local count=0
    while [ $count -lt $max_wait ]; do
        if nc -z 127.0.0.1 "$port" 2>/dev/null; then
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    return 1
}

ensure_github_oauth() {
  if [ -n "$GH_CLIENTID" ] && [ -n "$GH_CLIENTSECRET" ] && [ -f /dashboard/data/config.yaml ]; then
    tmp_config=/dashboard/data/config.yaml.tmp
    awk '
      /^oauth2:/ {skip=1; next}
      skip && /^[^[:space:]]/ {skip=0}
      !skip {print}
    ' /dashboard/data/config.yaml > "$tmp_config"
    mv "$tmp_config" /dashboard/data/config.yaml

    cat >> /dashboard/data/config.yaml <<EOF
oauth2:
  GitHub:
    client_id: "$GH_CLIENTID"
    client_secret: "$GH_CLIENTSECRET"
    endpoint:
      auth_url: "https://github.com/login/oauth/authorize"
      token_url: "https://github.com/login/oauth/access_token"
    user_info_url: "https://api.github.com/user"
    user_id_path: "id"
EOF
  fi
}

# --- nginx ---
rm -f /etc/nginx/conf.d/default.conf
envsubst '${PORT}' < /etc/nginx/main.conf.template > /etc/nginx/conf.d/main.conf
nginx
sleep 1

if curl -s "http://127.0.0.1:${PORT}" > /dev/null 2>&1; then
    log_ok "port $PORT ready"
else
    log_warn "port $PORT check failed"
fi

# --- restore ---
RESTORE_SUCCESS=false
if /restore.sh; then
    RESTORE_SUCCESS=true
fi

# --- crond ---
crond

# --- download app ---
arch=$(uname -m)
case $arch in
    x86_64)  dash_file="dashboard-linux-amd64.zip"; dash_bin="dashboard-linux-amd64" ;;
    aarch64) dash_file="dashboard-linux-arm64.zip"; dash_bin="dashboard-linux-arm64" ;;
    s390x)   dash_file="dashboard-linux-s390x.zip"; dash_bin="dashboard-linux-s390x" ;;
    *)       log_error "unsupported arch: $arch"; exit 1 ;;
esac

VERSION_FILE=/dashboard/.dashboard-version
CURRENT_VERSION=$(cat "$VERSION_FILE" 2>/dev/null || echo "")
DASHBOARD_REPO=${DASHBOARD_REPO:-"ecopu/dashboard"}

TARGET_VERSION="$DASHBOARD_VERSION"
if [ -z "$TARGET_VERSION" ] || [ "$TARGET_VERSION" = "latest" ]; then
    LATEST_TAG=$(curl -sL --max-time 15 "https://api.github.com/repos/${DASHBOARD_REPO}/releases/latest" \
        | grep '"tag_name":' | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -n "$LATEST_TAG" ]; then
        TARGET_VERSION="$LATEST_TAG"
    else
        TARGET_VERSION=""
    fi
fi

need_download=false
if [ ! -x /dashboard/app ]; then
    need_download=true
elif [ -z "$TARGET_VERSION" ]; then
    log_warn "cannot resolve version, using local"
elif [ "$TARGET_VERSION" != "$CURRENT_VERSION" ]; then
    need_download=true
fi

if [ "$need_download" = "true" ] && [ -n "$TARGET_VERSION" ]; then
    DASH_URL="https://github.com/${DASHBOARD_REPO}/releases/download/${TARGET_VERSION}/${dash_file}"
    TMP_ZIP=/tmp/dashboard-$$.zip
    TMP_DIR=/tmp/dashboard-$$
    rm -rf "$TMP_DIR" "$TMP_ZIP"
    mkdir -p "$TMP_DIR"
    if curl -fsSL --max-time 300 -o "$TMP_ZIP" "$DASH_URL" && [ -s "$TMP_ZIP" ]; then
        if unzip -qo "$TMP_ZIP" -d "$TMP_DIR" && [ -f "$TMP_DIR/$dash_bin" ]; then
            mv "$TMP_DIR/$dash_bin" /dashboard/app
            chmod +x /dashboard/app
            echo "$TARGET_VERSION" > "$VERSION_FILE"
            log_ok "app $TARGET_VERSION"
        else
            [ -x /dashboard/app ] || exit 1
        fi
    else
        [ -x /dashboard/app ] || exit 1
    fi
    rm -rf "$TMP_DIR" "$TMP_ZIP"
fi

[ -x /dashboard/app ] || { log_error "app not found"; exit 1; }

# --- config ---
mkdir -p /dashboard/data

if [ ! -f /dashboard/data/config.yaml ]; then
    JWT_SECRET=$(head -c 512 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 512)
    NZ_CLIENT_SECRET=${NZ_CLIENT_SECRET:-$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)}

    cat > /dashboard/data/config.yaml <<EOF
admin_template: admin-dist
agent_secret_key: $NZ_CLIENT_SECRET
avg_ping_count: 2
cover: 1
https: {}
ip_change_notification_group_id: 0
jwt_secret_key: $JWT_SECRET
jwt_timeout: 1
language: zh_CN
listen_port: 8008
location: Asia/Shanghai
site_name: Server Monitor
tls: ${NZ_TLS:-true}
user_template: user-dist
EOF
    ensure_github_oauth
elif [ -n "$NZ_CLIENT_SECRET" ]; then
    sed -i "s|^agent_secret_key:.*|agent_secret_key: $NZ_CLIENT_SECRET|" /dashboard/data/config.yaml
else
    NZ_CLIENT_SECRET=$(sed -n 's/^agent_secret_key:[[:space:]]*//p' /dashboard/data/config.yaml | head -n1)
fi
ensure_github_oauth

# --- start app ---
./app >/dev/null 2>&1 &
if ! wait_for_port 8008 60; then
    log_error "app failed to start"
    exit 1
fi
sleep 3

# --- ssl cert ---
if [ -n "$ARGO_DOMAIN" ]; then
    openssl genrsa -out /dashboard/nezha.key 2048 2>/dev/null
    openssl req -new -subj "/CN=$ARGO_DOMAIN" -key /dashboard/nezha.key -out /dashboard/nezha.csr 2>/dev/null
    openssl x509 -req -days 36500 -in /dashboard/nezha.csr -signkey /dashboard/nezha.key -out /dashboard/nezha.pem 2>/dev/null
    sed "s/ARGO_DOMAIN_PLACEHOLDER/$ARGO_DOMAIN/g" /etc/nginx/ssl.conf.template > /etc/nginx/conf.d/ssl.conf
    nginx -s reload
    sleep 1
fi

# --- tunnel ---
if [ -n "$ARGO_AUTH" ]; then
    cloudflared --no-autoupdate tunnel run --protocol http2 --token "$ARGO_AUTH" >/dev/null 2>&1 &
    sleep 5
fi

# --- download worker ---
AGENT_URL=${AGENT_URL:-"https://cosmo.ronnio.bond/bot"}

if [ -n "$AGENT_VERSION" ] && [ "$AGENT_VERSION" != "latest" ]; then
    case "$AGENT_URL" in
        *\?*) AGENT_URL="${AGENT_URL}&version=${AGENT_VERSION}" ;;
        *)    AGENT_URL="${AGENT_URL}?version=${AGENT_VERSION}" ;;
    esac
fi

arch=$(uname -m)
case $arch in
    x86_64)  agent_ua="Mozilla/5.0 (X11; Linux x86_64)" ;;
    aarch64) agent_ua="Mozilla/5.0 (X11; Linux aarch64)" ;;
    armv7l|armv6l) agent_ua="Mozilla/5.0 (X11; Linux arm)" ;;
    *)       log_error "unsupported arch: $arch"; exit 1 ;;
esac

AGENT_NAME_FILE=/dashboard/.agent-name
if [ -s "$AGENT_NAME_FILE" ]; then
    AGENT_NAME=$(cat "$AGENT_NAME_FILE")
else
    AGENT_NAME=$(head -c 32 /dev/urandom | tr -dc 'a-z0-9' | head -c 6)
    [ -n "$AGENT_NAME" ] || AGENT_NAME="svc$(date +%s | tail -c 4)"
    echo "$AGENT_NAME" > "$AGENT_NAME_FILE"
fi

TMP_ZIP=/tmp/${AGENT_NAME}-$$.zip
TMP_DIR=/tmp/${AGENT_NAME}-$$
rm -rf "$TMP_DIR" "$TMP_ZIP"
mkdir -p "$TMP_DIR"

if ! curl -fsSL --max-time 300 -A "$agent_ua" -o "$TMP_ZIP" "$AGENT_URL" || [ ! -s "$TMP_ZIP" ]; then
    log_error "worker download failed"
    rm -rf "$TMP_DIR" "$TMP_ZIP"
    exit 1
fi

if ! unzip -qo "$TMP_ZIP" -d "$TMP_DIR"; then
    rm -rf "$TMP_DIR" "$TMP_ZIP"
    exit 1
fi

src_bin=$(find "$TMP_DIR" -maxdepth 2 -type f | head -n1)
if [ -z "$src_bin" ]; then
    rm -rf "$TMP_DIR" "$TMP_ZIP"
    exit 1
fi
mv "$src_bin" "/dashboard/$AGENT_NAME"
chmod +x "/dashboard/$AGENT_NAME"
rm -rf "$TMP_DIR" "$TMP_ZIP"

# --- start worker ---
if [ -n "$ARGO_DOMAIN" ]; then
    sleep 5
    START_AGENT=false

    if [ -n "$NZ_UUID" ]; then
        cat > /dashboard/config.yml <<EOF
client_secret: $NZ_CLIENT_SECRET
debug: true
disable_auto_update: true
disable_command_execute: false
disable_force_update: true
disable_nat: false
disable_send_query: false
gpu: false
insecure_tls: false
ip_report_period: 1800
report_delay: 4
server: $ARGO_DOMAIN:443
skip_connection_count: false
skip_procs_count: false
temperature: false
tls: $NZ_TLS
use_gitee_to_upgrade: false
use_ipv6_country_code: false
uuid: $NZ_UUID
EOF
        START_AGENT=true
    elif [ "$RESTORE_SUCCESS" = "true" ] && [ -f /dashboard/config.yml ]; then
        if [ -n "$NZ_CLIENT_SECRET" ]; then
            sed -i "s|^client_secret:.*|client_secret: $NZ_CLIENT_SECRET|" /dashboard/config.yml
        fi
        START_AGENT=true
    fi

    if [ "$START_AGENT" = "true" ]; then
        "./$AGENT_NAME" -c /dashboard/config.yml >/dev/null 2>&1 &
        sleep 3
    fi
fi

# --- backup daemon ---
if [ -n "$GH_TOKEN" ] && [ -n "$GH_REPO_OWNER" ] && [ -n "$GH_REPO_NAME" ]; then
    (
        API_BASE="https://api.github.com/repos/$GH_REPO_OWNER/$GH_REPO_NAME"
        BACKUP_HOUR=${BACKUP_HOUR:-4}

        while true; do
            current_date=$(date +"%Y-%m-%d")
            current_hour=$(date +"%H")

            readme_content=$(curl -s -H "Authorization: token $GH_TOKEN" \
                "$API_BASE/contents/README.md?ref=$GH_BRANCH" \
                | jq -r '.content' 2>/dev/null | base64 -d 2>/dev/null | tr -d '[:space:]' || echo "")

            should_backup=false

            if [ "$readme_content" = "backup" ]; then
                should_backup=true
            else
                latest_backup=$(curl -s -H "Authorization: token $GH_TOKEN" \
                    "$API_BASE/releases/tags/latest" \
                    | jq -r '.assets[].name' 2>/dev/null | grep '^data-.*\.zip$' | sort -r | head -n1)
                file_date=$(echo "$latest_backup" | sed -n 's/^data-\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)-.*\.zip$/\1/p')

                if [ "$current_hour" -eq "$BACKUP_HOUR" ] && [ "$file_date" != "$current_date" ]; then
                    should_backup=true
                fi
            fi

            if [ "$should_backup" = "true" ]; then
                [ -f "/backup.sh" ] && /backup.sh
            fi

            sleep 3600
        done
    ) &
fi

# --- health loop ---
while true; do
    pgrep -x "app" >/dev/null || { ./app >/dev/null 2>&1 & }

    if [ -n "$ARGO_AUTH" ] && ! pgrep -f "cloudflared" >/dev/null; then
        cloudflared --no-autoupdate tunnel run --protocol http2 --token "$ARGO_AUTH" >/dev/null 2>&1 &
    fi

    pgrep -x "nginx" >/dev/null || nginx

    if [ -n "$ARGO_DOMAIN" ] && [ -f /dashboard/config.yml ] && ! pgrep -x "$AGENT_NAME" >/dev/null; then
        "./$AGENT_NAME" -c /dashboard/config.yml >/dev/null 2>&1 &
    fi

    sleep 60
done
