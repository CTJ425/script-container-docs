#!/bin/bash
# =================================================================
# RHEL 9 First Boot Initial Setup Script
# - Always configures the selected NIC with a static IPv4 address
# - Reads defaults from current DHCP/static runtime state when available
# - Interactive NIC Selection
# =================================================================

set -o pipefail

# 旗標檔案，用來判斷是否為首次執行
FLAG_FILE="/etc/firstboot_completed"

fail() {
    echo "Error: $*" >&2
    exit 1
}

run_or_fail() {
    "$@" || fail "Command failed: $*"
}

# 如果旗標檔案存在，直接離開
if [ -f "$FLAG_FILE" ]; then
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    fail "This script must be run as root."
fi

if ! command -v nmcli >/dev/null 2>&1; then
    fail "nmcli command not found. Please install/enable NetworkManager."
fi

if ! command -v hostnamectl >/dev/null 2>&1; then
    fail "hostnamectl command not found."
fi

# --- 動態偵測 OS 名稱 ---
if [ -f /etc/os-release ]; then
    # 匯入系統資訊檔案
    # shellcheck disable=SC1091
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
mapfile -t devices < <(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2 == "ethernet" {print $1}')
device_count=${#devices[@]}

if [ "$device_count" -eq 0 ]; then
    fail "No ethernet devices found. Aborting."
elif [ "$device_count" -eq 1 ]; then
    default_device=${devices[0]}
    read -r -e -p "Select device to edit [$default_device]: " ch_device
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

CON_NAME=$(nmcli -g GENERAL.CONNECTION device show "$ch_device" 2>/dev/null | head -n 1)
if [ "$CON_NAME" = "--" ]; then
    CON_NAME=""
fi
if [ -z "$CON_NAME" ]; then
    CON_NAME=$(nmcli -t -f NAME,DEVICE connection show | awk -F: -v dev="$ch_device" '$2 == dev {print $1; exit}')
fi
if [ -z "$CON_NAME" ]; then
    CON_NAME="$ch_device"
    echo "No existing connection profile found for '$ch_device'. Creating '$CON_NAME'."
    run_or_fail nmcli connection add type ethernet ifname "$ch_device" con-name "$CON_NAME" autoconnect yes
fi

echo "--- Step 2: Configure Network Settings for '$CON_NAME' ---"

# Prefer runtime values so DHCP-provided settings can be reused as defaults.
full_address=$(nmcli -g IP4.ADDRESS device show "$ch_device" 2>/dev/null | head -n 1 | cut -d'[' -f1)
if [ -z "$full_address" ]; then
    full_address=$(nmcli -g ipv4.addresses connection show "$CON_NAME" 2>/dev/null | head -n 1)
fi
ch_ipv4=$(echo "$full_address" | cut -d'/' -f1)
ch_netmask=$(echo "$full_address" | cut -s -d'/' -f2)
ch_gw4=$(nmcli -g IP4.GATEWAY device show "$ch_device" 2>/dev/null | head -n 1)
if [ -z "$ch_gw4" ]; then
    ch_gw4=$(nmcli -g ipv4.gateway connection show "$CON_NAME" 2>/dev/null | head -n 1)
fi
ch_dns4=$(nmcli -g IP4.DNS device show "$ch_device" 2>/dev/null | paste -sd ' ' -)
if [ -z "$ch_dns4" ]; then
    ch_dns4=$(nmcli -g ipv4.dns connection show "$CON_NAME" 2>/dev/null | paste -sd ' ' -)
fi

read -r -e -p "Change [$ch_ipv4] ipv4: " ipv4
if [ -z "$ipv4" ]; then
    ipv4="$ch_ipv4"
fi

read -r -e -p "Change [$ch_netmask] netmask (CIDR): " netmask
if [ -z "$netmask" ]; then
    netmask="$ch_netmask"
fi

read -r -e -p "Change [$ch_gw4] gateway: " gw4
if [ -z "$gw4" ]; then
    gw4="$ch_gw4"
fi

read -r -e -p "Change [$ch_dns4] dns: " dns4
if [ -z "$dns4" ]; then
    dns4="$ch_dns4"
fi

if [ -z "$ipv4" ]; then
    fail "IPv4 address is required for static configuration."
fi

if [ -z "$netmask" ]; then
    fail "CIDR netmask is required for static configuration."
fi

echo
echo "--- Step 3: Configure Hostname ---"
current_hostname=$(hostname)
read -r -e -p "Change [$current_hostname] hostname: " hostname_edit
if [ -z "$hostname_edit" ]; then
    hostname_edit=$current_hostname
fi
echo

echo "===== Start change nic setting ====="
run_or_fail nmcli connection modify "$CON_NAME" \
            ipv4.method manual \
            ipv4.addresses "$ipv4/$netmask" \
            ipv4.gateway "$gw4" \
            ipv4.dns "$dns4" \
            ipv4.ignore-auto-dns yes \
            autoconnect yes
nmcli connection down "$CON_NAME" >/dev/null 2>&1 || true
run_or_fail nmcli connection up "$CON_NAME"
echo "===== Change nic setting done ====="
echo ""

echo "===== Start change hostname ====="
run_or_fail hostnamectl set-hostname "$hostname_edit"
echo "Hostname has been set to: $hostname_edit"
echo "===== Change hostname done ====="

# --- 首次執行判斷的收尾工作 ---
echo
echo "Setup is complete. Creating flag file to prevent this script from running again."
run_or_fail touch "$FLAG_FILE"
read -r -p "Reboot now to apply all changes? (y/n): " reboot_confirm
if [[ "$reboot_confirm" == "y" || "$reboot_confirm" == "Y" ]]; then
    echo "Rebooting..."
    reboot
fi
