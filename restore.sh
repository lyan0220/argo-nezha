#!/bin/bash
set -u

if [ -z "${GH_TOKEN:-}" ] || [ -z "${GH_REPO_OWNER:-}" ] || [ -z "${GH_REPO_NAME:-}" ]; then
    exit 1
fi

if [ -z "${ZIP_PASSWORD:-}" ]; then
    exit 1
fi

for cmd in curl jq unzip; do
    command -v "$cmd" >/dev/null 2>&1 || exit 1
done

GH_BRANCH="${GH_BRANCH:-main}"
DATA_DIR="${DATA_DIR:-/dashboard/data}"
CONFIG_PATH="${CONFIG_PATH:-/dashboard/config.yml}"
API_BASE="https://api.github.com/repos/$GH_REPO_OWNER/$GH_REPO_NAME"

TEMP_DIR="/tmp/rst-$$"
TMP_FILE="$TEMP_DIR/backup.zip"
mkdir -p "$TEMP_DIR"
trap 'rm -rf "$TEMP_DIR"' EXIT

BACKUP_FILE="${1:-}"
ASSET_ID=""

if [ -z "$BACKUP_FILE" ]; then
    ASSET_JSON=$(curl -s -H "Authorization: token $GH_TOKEN" \
        "$API_BASE/releases/tags/latest" \
        | jq -c '[.assets[] | select(.name | test("^data-.*\\.zip$"))] | sort_by(.created_at) | reverse | .[0]')

    if [ -z "$ASSET_JSON" ] || [ "$ASSET_JSON" = "null" ]; then
        exit 1
    fi

    BACKUP_FILE=$(echo "$ASSET_JSON" | jq -r '.name')
    ASSET_ID=$(echo "$ASSET_JSON" | jq -r '.id')
else
    ASSET_ID=$(curl -s -H "Authorization: token $GH_TOKEN" \
        "$API_BASE/releases/tags/latest" \
        | jq -r --arg name "$BACKUP_FILE" '.assets[] | select(.name == $name) | .id')

    if [ -z "$ASSET_ID" ] || [ "$ASSET_ID" = "null" ]; then
        exit 1
    fi
fi

[ -z "$BACKUP_FILE" ] || [ -z "$ASSET_ID" ] && exit 1

HTTP_CODE=$(curl -L -w "%{http_code}" \
    -H "Authorization: token $GH_TOKEN" \
    -H "Accept: application/octet-stream" \
    -o "$TMP_FILE" \
    "$API_BASE/releases/assets/$ASSET_ID")

[ "$HTTP_CODE" != "200" ] && exit 1
[ -s "$TMP_FILE" ] || exit 1

unzip -t -P "$ZIP_PASSWORD" "$TMP_FILE" >/dev/null 2>&1 || exit 1
unzip -P "$ZIP_PASSWORD" -o "$TMP_FILE" -d "$TEMP_DIR" || exit 1
[ -d "$TEMP_DIR/data" ] || exit 1

if [ -d "$DATA_DIR" ] && [ -f "$DATA_DIR/sqlite.db" ]; then
    cp -R "$DATA_DIR" "${DATA_DIR}.bak.$(date +%s)"
fi

mkdir -p "$DATA_DIR"
cp -R "$TEMP_DIR/data/"* "$DATA_DIR/"

if [ -f "$TEMP_DIR/config.yml" ]; then
    cp "$TEMP_DIR/config.yml" "$CONFIG_PATH"
    chmod 644 "$CONFIG_PATH"
fi

chown -R nobody:nogroup "$DATA_DIR" 2>/dev/null || true
chmod -R 755 "$DATA_DIR"
