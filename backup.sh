#!/bin/bash
# scripts/backup.sh - Nezha 数据备份脚本 (Releases 方案优化版)
set -u

###########################################
# Nezha 备份脚本 - 附件上传版
###########################################

# 必要变量检查
if [ -z "${GH_TOKEN:-}" ] || [ -z "${GH_REPO_OWNER:-}" ] || [ -z "${GH_REPO_NAME:-}" ]; then
    echo "[WARN] 缺少 GH_TOKEN 或 GITHUB_REPO，跳过备份"
    exit 0
fi

if [ -z "${ZIP_PASSWORD:-}" ]; then
    echo "[WARN] 缺少 ZIP_PASSWORD，跳过备份"
    exit 0
fi

# 检查系统必要依赖
for cmd in curl jq zip; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[ERROR] 系统缺少必要命令: $cmd，请先安装"
        exit 1
    fi
done

# 配置
DATA_DIR="${DATA_DIR:-/dashboard/data}"
CONFIG_PATH="${CONFIG_PATH:-/dashboard/config.yml}"
GH_BRANCH="${GH_BRANCH:-main}"
KEEP_BACKUPS="${KEEP_BACKUPS:-5}"
API_BASE="https://api.github.com/repos/$GH_REPO_OWNER/$GH_REPO_NAME"
TIMESTAMP=$(TZ='Asia/Shanghai' date +"%Y-%m-%d-%H%M%S")
BACKUP_FILE="data-${TIMESTAMP}.zip"

echo "=========================================="
echo " Nezha 数据备份 (Release模式)"
echo "=========================================="
echo "[INFO] 开始备份: $BACKUP_FILE"
echo "[INFO] 数据目录: $DATA_DIR"

if [ ! -d "$DATA_DIR" ]; then
    echo "[ERROR] 数据目录不存在: $DATA_DIR"
    exit 1
fi

TEMP_DIR="/tmp/nezha-backup-$$"
mkdir -p "$TEMP_DIR"
cd "$TEMP_DIR" || exit 1

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

echo "[INFO] 复制数据..."
cp -R "$DATA_DIR" "$TEMP_DIR/data"

if [ -f "$DATA_DIR/sqlite.db" ]; then
    if command -v sqlite3 >/dev/null 2>&1; then
        echo "[INFO] 生成 SQLite 一致性快照..."
        sqlite3 "$DATA_DIR/sqlite.db" ".backup '$TEMP_DIR/data/sqlite.db'" \
            || echo "[WARN] .backup 失败，回退使用 cp 拷贝的副本"
        
        echo "[INFO] 清理 SQLite 历史数据..."
        sqlite3 "$TEMP_DIR/data/sqlite.db" <<'EOF'
.bail off
BEGIN;
DELETE FROM service_histories WHERE created_at < datetime('now', 'localtime', '-30 days');
DELETE FROM transfers WHERE created_at < datetime('now', 'localtime', '-30 days');
COMMIT;
EOF
        delete_rc=$?

        if [ "$delete_rc" -eq 0 ]; then
            echo "[INFO] 清理完成，执行 VACUUM..."
            sqlite3 "$TEMP_DIR/data/sqlite.db" "VACUUM;" \
                || echo "[WARN] VACUUM 失败，跳过但备份继续"
        else
            echo "[WARN] 清理错误（rc=$delete_rc），跳过 VACUUM"
        fi
    fi
fi

if [ -f "$CONFIG_PATH" ]; then
    echo "[INFO] 包含探针配置: $CONFIG_PATH"
    cp "$CONFIG_PATH" "$TEMP_DIR/config.yml"
fi

echo "[INFO] 压缩数据（加密）..."
if [ -f "$TEMP_DIR/config.yml" ]; then
    zip -r -6 -P "$ZIP_PASSWORD" "$BACKUP_FILE" data/ config.yml >/dev/null 2>&1
else
    zip -r -6 -P "$ZIP_PASSWORD" "$BACKUP_FILE" data/ >/dev/null 2>&1
fi

if [ ! -f "$BACKUP_FILE" ]; then
    echo "[ERROR] 压缩失败"
    exit 1
fi

BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
echo "[INFO] 备份文件大小: $BACKUP_SIZE"

# ==========================================================
# 1. 获取或创建 Release (固定标签 latest)
# ==========================================================
echo "[INFO] 检查/创建 Release 节点..."
RELEASE_ID=$(curl -s -H "Authorization: token $GH_TOKEN" "$API_BASE/releases/tags/latest" | jq -r '.id // empty')

if [ -z "$RELEASE_ID" ] || [ "$RELEASE_ID" = "null" ]; then
    echo "[INFO] 未找到 latest 标签的 Release，正在创建..."
    RELEASE_ID=$(curl -s -X POST \
        -H "Authorization: token $GH_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"tag_name":"latest","name":"Nezha Data Backups","body":"自动备份存放节点"}' \
        "$API_BASE/releases" | jq -r '.id')
    
    if [ -z "$RELEASE_ID" ] || [ "$RELEASE_ID" = "null" ]; then
        echo "[ERROR] 创建 Release 失败"
        exit 1
    fi
fi

# ==========================================================
# 2. 上传备份文件作为附件 (二进制直传，省内存)
# ==========================================================
echo "[INFO] 上传备份文件到 Release 附件..."
UPLOAD_URL="https://uploads.github.com/repos/$GH_REPO_OWNER/$GH_REPO_NAME/releases/$RELEASE_ID/assets?name=$BACKUP_FILE"

UPLOAD_RESP=$(curl -s -X POST \
    -H "Authorization: token $GH_TOKEN" \
    -H "Content-Type: application/zip" \
    --data-binary @"$BACKUP_FILE" \
    "$UPLOAD_URL")

if echo "$UPLOAD_RESP" | jq -e '.id' >/dev/null 2>&1; then
    echo "[SUCCESS] 备份文件附件已上传 ✓"
else
    echo "[ERROR] 上传失败: $(echo "$UPLOAD_RESP" | jq -r '.message // "未知错误"')"
    exit 1
fi

# ==========================================================
# 3. 删除旧附件（仅保留设定的数量）
# ==========================================================
echo "[INFO] 清理旧备份附件（保留 ${KEEP_BACKUPS} 个）..."
# 获取该 release 下所有 assets，保留最新的 KEEP_BACKUPS 个，其余列为待删除
OLD_ASSETS_JSON=$(curl -s -H "Authorization: token $GH_TOKEN" "$API_BASE/releases/$RELEASE_ID/assets" \
    | jq -c "[sort_by(.created_at) | reverse | .[$KEEP_BACKUPS:] | .[] | {id: .id, name: .name}]")

if [ "$OLD_ASSETS_JSON" != "[]" ] && [ "$OLD_ASSETS_JSON" != "null" ]; then
    echo "$OLD_ASSETS_JSON" | jq -c '.[]' | while read -r asset; do
        ASSET_ID=$(echo "$asset" | jq -r '.id')
        ASSET_NAME=$(echo "$asset" | jq -r '.name')
        echo "[INFO] 正在删除历史附件: $ASSET_NAME"
        curl -s -X DELETE -H "Authorization: token $GH_TOKEN" "$API_BASE/releases/assets/$ASSET_ID" >/dev/null
    done
else
    echo "[INFO] 没有需要清理的历史附件"
fi

# ==========================================================
# 4. 更新 README.md
# ==========================================================
echo "[INFO] 更新 README.md..."
README_SHA=$(curl -s -H "Authorization: token $GH_TOKEN" \
    "$API_BASE/contents/README.md?ref=$GH_BRANCH" | jq -r '.sha // empty')

# 由于 base64 -w 0 某些系统不兼容，提供兜底
b64_encode() {
    base64 -w 0 2>/dev/null || base64
}

README_TEXT="# Nezha 数据备份

## 最新备份信息
- **文件名**: \`$BACKUP_FILE\`
- **存储位置**: Github [Releases 附件](../../releases/latest)
- **备份时间**: $(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')
- **文件大小**: $BACKUP_SIZE

## 恢复说明
设置环境变量后容器会自动获取最新的 Release 附件进行恢复。

## 手动触发备份
将此文件内容修改为 \`backup\` 即可触发手动备份。

## 环境变量
- \`GH_REPO_OWNER\`: GitHub 用户名
- \`GH_REPO_NAME\`: GitHub 仓库名称
- \`GH_TOKEN\`: GitHub Token
- \`GH_BRANCH\`: GitHub 备份分支
- \`ZIP_PASSWORD\`: 备份密码
"

README_B64=$(echo -n "$README_TEXT" | b64_encode)

if [ -n "$README_SHA" ]; then
    jq -n --arg msg "更新 README (Release模式): $BACKUP_FILE" \
        --arg content "$README_B64" \
        --arg sha "$README_SHA" \
        --arg branch "$GH_BRANCH" \
        '{message: $msg, content: $content, sha: $sha, branch: $branch}' > readme.json
else
    jq -n --arg msg "创建 README" \
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
echo "[SUCCESS] README.md 已更新 ✓"

echo "=========================================="
echo "[SUCCESS] 备份完成: $BACKUP_FILE 🎉"
echo "=========================================="