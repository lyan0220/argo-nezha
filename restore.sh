#!/bin/bash
# scripts/restore.sh - Nezha 数据恢复脚本 (Releases 方案适配版)
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

# 检查系统必要依赖
for cmd in curl jq unzip; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[ERROR] 系统缺少必要命令: $cmd，请先安装"
        exit 1
    fi
done

# 配置
GH_BRANCH="${GH_BRANCH:-main}"
DATA_DIR="${DATA_DIR:-/dashboard/data}"
CONFIG_PATH="${CONFIG_PATH:-/dashboard/config.yml}"
API_BASE="https://api.github.com/repos/$GH_REPO_OWNER/$GH_REPO_NAME"

echo "=========================================="
echo " Nezha 数据恢复 (Release模式)"
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
ASSET_ID=""

# 从 Release 接口获取文件信息
if [ -z "$BACKUP_FILE" ]; then
    echo "[INFO] 获取 latest Release 中的最新备份..."
    
    # 获取最新的 zip 附件信息（按创建时间倒序，取最新一个）
    ASSET_JSON=$(curl -s -H "Authorization: token $GH_TOKEN" \
        "$API_BASE/releases/tags/latest" \
        | jq -c '[.assets[] | select(.name | test("^data-.*\\.zip$"))] | sort_by(.created_at) | reverse | .[0]')
        
    if [ -z "$ASSET_JSON" ] || [ "$ASSET_JSON" = "null" ]; then
        echo "[ERROR] 未在 latest Release 中找到备份附件"
        exit 1
    fi
    
    BACKUP_FILE=$(echo "$ASSET_JSON" | jq -r '.name')
    ASSET_ID=$(echo "$ASSET_JSON" | jq -r '.id')
else
    echo "[INFO] 指定了备份文件: $BACKUP_FILE，正在查询对应的 Asset ID..."
    ASSET_ID=$(curl -s -H "Authorization: token $GH_TOKEN" \
        "$API_BASE/releases/tags/latest" \
        | jq -r --arg name "$BACKUP_FILE" '.assets[] | select(.name == $name) | .id')
        
    if [ -z "$ASSET_ID" ] || [ "$ASSET_ID" = "null" ]; then
        echo "[ERROR] 在 Release 中找不到指定的文件: $BACKUP_FILE"
        exit 1
    fi
fi

if [ -z "$BACKUP_FILE" ] || [ -z "$ASSET_ID" ]; then
    echo "[ERROR] 无法确定备份文件或附件 ID"
    exit 1
fi

echo "[INFO] 准备恢复备份文件: $BACKUP_FILE (Asset ID: $ASSET_ID)"

# 下载备份文件 (通过 Asset ID 请求 octet-stream 并跟随重定向)
echo "[INFO] 下载备份文件..."
HTTP_CODE=$(curl -L -w "%{http_code}" \
    -H "Authorization: token $GH_TOKEN" \
    -H "Accept: application/octet-stream" \
    -o "$TMP_FILE" \
    "$API_BASE/releases/assets/$ASSET_ID")

# 检查 HTTP 状态码 (200 正常下载，可能存在 302 重定向到 S3 被 curl -L 处理后最终返回 200)
if [ "$HTTP_CODE" != "200" ]; then
    echo "[ERROR] 下载失败 (最终 HTTP 状态码: $HTTP_CODE)"
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

# 恢复探针配置（如果备份中包含）
if [ -f "$TEMP_DIR/config.yml" ]; then
    echo "[INFO] 恢复探针配置到 $CONFIG_PATH"
    cp "$TEMP_DIR/config.yml" "$CONFIG_PATH"
    chmod 644 "$CONFIG_PATH"
fi

# 设置权限
chown -R nobody:nogroup "$DATA_DIR" 2>/dev/null || true
chmod -R 755 "$DATA_DIR"

echo "=========================================="
echo "[SUCCESS] 恢复完成 🎉"
echo "=========================================="
echo "[INFO] 恢复的文件:"
ls -la "$DATA_DIR"