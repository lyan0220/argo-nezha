#!/bin/bash
# scripts/restore.sh - Nezha 数据恢复脚本
set -u

###########################################
# Nezha 恢复脚本
###########################################

# 必要变量检查
if [ -z "${GH_TOKEN:-}" ] || [ -z "${GH_REPO_OWNER:-}" ] || [ -z "${GH_REPO_NAME:-}" ]; then
    echo "[ERROR] 请设置 GH_TOKEN、GH_REPO_OWNER 和 GH_REPO_NAME"
    exit 1
fi

if [ -z "${ZIP_PASSWORD:-}" ]; then
    echo "[ERROR] 请设置 ZIP_PASSWORD"
    exit 1
fi

# 配置
GH_BRANCH="${GH_BRANCH:-main}"
DATA_DIR="${DATA_DIR:-/dashboard/data}"
API_BASE="https://api.github.com/repos/$GH_REPO_OWNER/$GH_REPO_NAME"

echo "=========================================="
echo " Nezha 数据恢复"
echo "=========================================="

# 临时目录
TEMP_DIR="/tmp/nezha-restore-$$"
TMP_FILE="$TEMP_DIR/backup.zip"
mkdir -p "$TEMP_DIR"

# 清理函数
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# 获取备份文件名
BACKUP_FILE="${1:-}"

if [ -z "$BACKUP_FILE" ]; then
    echo "[INFO] 获取最新备份..."
    
    # 优先从 README.md 获取
    README_CONTENT=$(curl -sf -H "Authorization: token $GH_TOKEN" \
        "$API_BASE/contents/README.md?ref=$GH_BRANCH" \
        | jq -r '.content' | base64 -d 2>/dev/null || echo "")
    
    # 从 README 中提取文件名
    BACKUP_FILE=$(echo "$README_CONTENT" | grep -oE 'data-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}\.zip' | head -n1)
    
    # 如果 README 中没有，从文件列表获取
    if [ -z "$BACKUP_FILE" ]; then
        echo "[INFO] 从文件列表获取最新备份..."
        BACKUP_FILE=$(curl -sf -H "Authorization: token $GH_TOKEN" \
            "$API_BASE/contents?ref=$GH_BRANCH" \
            | jq -r '.[].name' | grep '^data-.*\.zip$' | sort -r | head -n1)
    fi
fi

if [ -z "$BACKUP_FILE" ]; then
    echo "[ERROR] 未找到备份文件"
    exit 1
fi

echo "[INFO] 备份文件: $BACKUP_FILE"

# 下载备份文件
echo "[INFO] 下载备份文件..."
HTTP_CODE=$(curl -L -w "%{http_code}" \
    -H "Authorization: token $GH_TOKEN" \
    -H "Accept: application/vnd.github.v3.raw" \
    -o "$TMP_FILE" \
    "$API_BASE/contents/$BACKUP_FILE?ref=$GH_BRANCH")

if [ "$HTTP_CODE" != "200" ]; then
    echo "[ERROR] 下载失败 (HTTP $HTTP_CODE)"
    exit 1
fi

if [ ! -s "$TMP_FILE" ]; then
    echo "[ERROR] 下载的文件为空"
    exit 1
fi

echo "[INFO] 文件大小: $(du -h "$TMP_FILE" | cut -f1)"

# 验证 zip 文件
echo "[INFO] 验证备份文件..."
if ! unzip -t -P "$ZIP_PASSWORD" "$TMP_FILE" >/dev/null 2>&1; then
    echo "[ERROR] 备份文件损坏或密码错误"
    exit 1
fi

# 解压到临时目录
echo "[INFO] 解压备份..."
if ! unzip -P "$ZIP_PASSWORD" -o "$TMP_FILE" -d "$TEMP_DIR"; then
    echo "[ERROR] 解压失败"
    exit 1
fi

# 检查解压结果
if [ ! -d "$TEMP_DIR/data" ]; then
    echo "[ERROR] 解压失败，未找到 data 目录"
    exit 1
fi

# 备份现有数据（如果存在）
if [ -d "$DATA_DIR" ] && [ -f "$DATA_DIR/sqlite.db" ]; then
    BACKUP_EXISTING="${DATA_DIR}.bak.$(date +%s)"
    echo "[INFO] 备份现有数据到: $BACKUP_EXISTING"
    cp -R "$DATA_DIR" "$BACKUP_EXISTING"
fi

# 恢复数据
echo "[INFO] 恢复数据到 $DATA_DIR..."
mkdir -p "$DATA_DIR"
cp -R "$TEMP_DIR/data/"* "$DATA_DIR/"

# 设置权限
chown -R nobody:nogroup "$DATA_DIR" 2>/dev/null || true
chmod -R 755 "$DATA_DIR"

echo "=========================================="
echo "[SUCCESS] 恢复完成 🎉"
echo "=========================================="
echo "[INFO] 恢复的文件:"
ls -la "$DATA_DIR"
