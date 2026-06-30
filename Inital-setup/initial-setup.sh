#!/bin/bash
# =================================================================
# RHEL 9 First Boot Initial Setup Script (Final Corrected Version)
# - Uses robust machine-readable commands to get settings
# - Interactive NIC Selection
# - Based on your original, proven logic
# =================================================================

# 旗標檔案，用來判斷是否為首次執行
FLAG_FILE="/etc/firstboot_completed"

# 如果旗標檔案存在，直接離開
if [ -f "$FLAG_FILE" ]; then
    exit 0
fi

# --- 動態偵測 OS 名稱 ---
if [ -f /etc/os-release ]; then
    # 匯入系統資訊檔案
    . /etc/os-release
    # 優先使用 PRETTY_NAME (較完整)，若無則使用 NAME，再沒有則預設為 "Linux System"
    SYSTEM_NAME="${PRETTY_NAME:-${NAME:-Linux System}}"
else
    SYSTEM_NAME="Linux System"
fi

# --- 清除畫面，顯示動態歡迎訊息 ---
clear
echo "=========================================================="
echo " Welcome to $SYSTEM_NAME Initial Setup"
echo " This script will run only once on the first root login."
echo "=========================================================="
echo


# --- 互動式網卡選擇 ---
echo "--- Step 1: Select Network Interface ---"
mapfile -t devices < <(nmcli -t -f DEVICE,TYPE device status | grep 'ethernet' | cut -d: -f1)
device_count=${#devices[@]}

if [ "$device_count" -eq 0 ]; then
    echo "Error: No ethernet devices found. Aborting."
    exit 1
elif [ "$device_count" -eq 1 ]; then
    default_device=${devices[0]}
    read -e -p "Select device to edit [$default_device]: " ch_device
    if [ -z "$ch_device" ]; then
        ch_device="$default_device"
    fi
else
    echo "Multiple ethernet devices found. Please choose one:"
    select device in "${devices[@]}"; do
        if [[ -n "$device" ]]; then
            ch_device=$device
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done
fi
echo "You selected: $ch_device"
echo

CON_NAME=$(nmcli -t -f NAME,DEVICE connection show | grep -E ":($ch_device)?$" | cut -d: -f1 | head -n 1)
if [ -z "$CON_NAME" ]; then
    echo "Error: Could not find connection profile for device '$ch_device'. Aborting."
    exit 1
fi

echo "--- Step 2: Configure Network Settings for '$CON_NAME' ---"
# --- [根本性修正] 使用 nmcli 的機器可讀模式 (-g) 來獲取設定，避免所有解析錯誤 ---
full_address=$(nmcli -g ipv4.addresses connection show "$CON_NAME" || true)
ch_ipv4=$(echo "$full_address" | cut -d'/' -f1)
ch_netmask=$(echo "$full_address" | cut -d'/' -f2)
ch_gw4=$(nmcli -g ipv4.gateway connection show "$CON_NAME" || true)
# 這個方法可以正確處理一個或多個 DNS，且保證輸出的純淨
ch_dns4=$(nmcli -g ipv4.dns connection show "$CON_NAME" || true)

# --- 您的原始互動邏輯 (完全保留) ---
read -e -p "Change [$ch_ipv4] ipv4: " ipv4
if [ -z "$ipv4" ]; then
    ipv4="$ch_ipv4"
fi

read -e -p "Change [$ch_netmask] netmask (CIDR): " netmask
if [ -z "$netmask" ]; then
    netmask="$ch_netmask"
fi

read -e -p "Change [$ch_gw4] gateway: " gw4
if [ -z "$gw4" ]; then
    gw4="$ch_gw4"
fi

read -e -p "Change [$ch_dns4] dns: " dns4
if [ -z "$dns4" ]; then
    dns4="$ch_dns4"
fi

echo
echo "--- Step 3: Configure Hostname ---"
current_hostname=$(hostname)
read -e -p "Change [$current_hostname] hostname: " hostname_edit
if [ -z "$hostname_edit" ]; then
    hostname_edit=$current_hostname
fi
echo

echo "===== Start change nic setting ====="
nmcli connection modify "$CON_NAME" \
            ipv4.method manual \
            ipv4.addresses "$ipv4/$netmask" \
            ipv4.gateway "$gw4" \
            ipv4.dns "$dns4" \
            autoconnect yes
nmcli connection down "$CON_NAME" && nmcli connection up "$CON_NAME"
echo "===== Change nic setting done ====="
echo ""

echo "===== Start change hostname ====="
hostnamectl set-hostname "$hostname_edit"
echo "Hostname has been set to: $hostname_edit"
echo "===== Change hostname done ====="

# --- 首次執行判斷的收尾工作 ---
echo
echo "Setup is complete. Creating flag file to prevent this script from running again."
touch "$FLAG_FILE"
read -p "Reboot now to apply all changes? (y/n): " reboot_confirm
if [[ "$reboot_confirm" == "y" || "$reboot_confirm" == "Y" ]]; then
    echo "Rebooting..."
    reboot
fi