#!/bin/bash

# --- 請在這裡設定您的目錄 ---
# SOURCE_DIR: 您存放 ISO 檔案的根目錄 (腳本會從這裡開始往下掃描)
# TARGET_DIR: Proxmox VE 存放 ISO 的目錄
SOURCE_DIR="/mnt/pve/ISO" # <--- 您的設定
TARGET_DIR="/mnt/pve/ISO/template/iso" # <-- 修正：移除了結尾的斜線

# --- Script 主體 ---
echo "============================================="
echo "開始同步 ISO 檔案連結..."
echo "來源目錄 (Source): $SOURCE_DIR"
echo "目標目錄 (Target): $TARGET_DIR"
echo "============================================="

# 安全性檢查：確認目錄是否存在
if [ ! -d "$SOURCE_DIR" ]; then
    echo "[錯誤] 來源目錄 '$SOURCE_DIR' 不存在。請檢查您的設定。"
    exit 1
fi

if [ ! -d "$TARGET_DIR" ]; then
    echo "[錯誤] 目標目錄 '$TARGET_DIR' 不存在。請確認 Proxmox VE 的儲存設定正確。"
    exit 1
fi

# 步驟 1: 清理目標目錄中所有舊的、失效的符號連結
echo -n "正在清理舊的連結..."
find "$TARGET_DIR" -maxdepth 1 -type l -exec rm {} \;
echo " 完成。"

# 步驟 2: 尋找所有 .iso 檔案並建立新的符號連結
echo "正在掃描來源目錄並建立新連結..."
COUNT=0
find "$SOURCE_DIR" \
    -path "$TARGET_DIR" -prune -o \
    -type d -name "@eaDir" -prune -o \
    -type f -iname "*.iso" \
    -print0 | while IFS= read -r -d $'\0' iso_file; do
        filename=$(basename "$iso_file")
        if [ ! -e "${TARGET_DIR}/${filename}" ]; then
            ln -s "$iso_file" "${TARGET_DIR}/${filename}"
            echo "  -> 已連結: $filename"
            ((COUNT++))
        else
            echo "  -> 已跳過 (目標檔案已存在): $filename"
        fi
    done

echo "============================================="
echo "處理完成！總共建立了 $COUNT 個新的符號連結。"
echo "============================================="
