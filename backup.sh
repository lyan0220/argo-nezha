#!/bin/bash
set -u

if [ -z "${GH_TOKEN:-}" ] || [ -z "${GH_REPO_OWNER:-}" ] || [ -z "${GH_REPO_NAME:-}" ]; then
    exit 0
fi

if [ -z "${ZIP_PASSWORD:-}" ]; then
    exit 0
fi

for cmd in curl jq zip; do
    command -v "$cmd" >/dev/null 2>&1 || exit 1
done

DATA_DIR="${DATA_DIR:-/dashboard/data}"
CONFIG_PATH="${CONFIG_PATH:-/dashboard/config.yml}"
GH_BRANCH="${GH_BRANCH:-main}"
KEEP_BACKUPS="${KEEP_BACKUPS:-5}"
API_BASE="https://api.github.com/repos/$GH_REPO_OWNER/$GH_REPO_NAME"
TIMESTAMP=$(TZ='Asia/Shanghai' date +"%Y-%m-%d-%H%M%S")
BACKUP_FILE="data-${TIMESTAMP}.zip"

[ -d "$DATA_DIR" ] || exit 1

TEMP_DIR="/tmp/bak-$$"
mkdir -p "$TEMP_DIR"
cd "$TEMP_DIR" || exit 1
trap 'rm -rf "$TEMP_DIR"' EXIT

cp -R "$DATA_DIR" "$TEMP_DIR/data"

if [ -f "$DATA_DIR/sqlite.db" ] && command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$DATA_DIR/sqlite.db" ".backup '$TEMP_DIR/data/sqlite.db'" 2>/dev/null
    sqlite3 "$TEMP_DIR/data/sqlite.db" <<'EOF' 2>/dev/null
.bail off
BEGIN;
DELETE FROM service_histories WHERE created_at < datetime('now', 'localtime', '-30 days');
DELETE FROM transfers WHERE created_at < datetime('now', 'localtime', '-30 days');
COMMIT;
EOF
    sqlite3 "$TEMP_DIR/data/sqlite.db" "VACUUM;" 2>/dev/null
fi

[ -f "$CONFIG_PATH" ] && cp "$CONFIG_PATH" "$TEMP_DIR/config.yml"

if [ -f "$TEMP_DIR/config.yml" ]; then
    zip -r -6 -P "$ZIP_PASSWORD" "$BACKUP_FILE" data/ config.yml >/dev/null 2>&1
else
    zip -r -6 -P "$ZIP_PASSWORD" "$BACKUP_FILE" data/ >/dev/null 2>&1
fi

[ -f "$BACKUP_FILE" ] || exit 1
BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)

RELEASE_ID=$(curl -s -H "Authorization: token $GH_TOKEN" "$API_BASE/releases/tags/latest" | jq -r '.id // empty')

if [ -z "$RELEASE_ID" ] || [ "$RELEASE_ID" = "null" ]; then
    RELEASE_ID=$(curl -s -X POST \
        -H "Authorization: token $GH_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"tag_name":"latest","name":"Data Backups","body":"auto"}' \
        "$API_BASE/releases" | jq -r '.id')
    [ -z "$RELEASE_ID" ] || [ "$RELEASE_ID" = "null" ] && exit 1
fi

UPLOAD_URL="https://uploads.github.com/repos/$GH_REPO_OWNER/$GH_REPO_NAME/releases/$RELEASE_ID/assets?name=$BACKUP_FILE"
UPLOAD_RESP=$(curl -s -X POST \
    -H "Authorization: token $GH_TOKEN" \
    -H "Content-Type: application/zip" \
    --data-binary @"$BACKUP_FILE" \
    "$UPLOAD_URL")

echo "$UPLOAD_RESP" | jq -e '.id' >/dev/null 2>&1 || exit 1

OLD_ASSETS_JSON=$(curl -s -H "Authorization: token $GH_TOKEN" "$API_BASE/releases/$RELEASE_ID/assets" \
    | jq -c "[sort_by(.created_at) | reverse | .[$KEEP_BACKUPS:] | .[] | {id: .id, name: .name}]")

if [ "$OLD_ASSETS_JSON" != "[]" ] && [ "$OLD_ASSETS_JSON" != "null" ]; then
    echo "$OLD_ASSETS_JSON" | jq -c '.[]' | while read -r asset; do
        ASSET_ID=$(echo "$asset" | jq -r '.id')
        curl -s -X DELETE -H "Authorization: token $GH_TOKEN" "$API_BASE/releases/assets/$ASSET_ID" >/dev/null
    done
fi

b64_encode() { base64 -w 0 2>/dev/null || base64; }

README_SHA=$(curl -s -H "Authorization: token $GH_TOKEN" \
    "$API_BASE/contents/README.md?ref=$GH_BRANCH" | jq -r '.sha // empty')

README_TEXT="# Data Backups

- **File**: \`$BACKUP_FILE\`
- **Location**: [Releases](../../releases/latest)
- **Time**: $(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')
- **Size**: $BACKUP_SIZE

To trigger manual backup, replace this file content with \`backup\`.
"

README_B64=$(echo -n "$README_TEXT" | b64_encode)

if [ -n "$README_SHA" ]; then
    jq -n --arg msg "backup: $BACKUP_FILE" \
        --arg content "$README_B64" \
        --arg sha "$README_SHA" \
        --arg branch "$GH_BRANCH" \
        '{message: $msg, content: $content, sha: $sha, branch: $branch}' > readme.json
else
    jq -n --arg msg "init" \
        --arg content "$README_B64" \
        --arg branch "$GH_BRANCH" \
        '{message: $msg, content: $content, branch: $branch}' > readme.json
fi

curl -s -X PUT \
    -H "Authorization: token $GH_TOKEN" \
    -H "Content-Type: application/json" \
    -d @readme.json \
    "$API_BASE/contents/README.md" >/dev/null

rm -f readme.json
