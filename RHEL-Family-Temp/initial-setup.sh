#!/usr/bin/env bash
# =================================================================
# RHEL Family First Boot Initial Setup Script
# - Always configures the selected NIC with a static IPv4 address
# - Reads defaults from current DHCP/static runtime state when available
# - Interactive NIC Selection & Validation
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

if ! mkdir /run/initial-setup.lock 2>/dev/null; then
    echo "Warning: Another instance of initial-setup is running." >&2
    exit 0
fi
trap 'rm -rf /run/initial-setup.lock' EXIT

if ! command -v nmcli >/dev/null 2>&1; then
    fail "nmcli command not found. Please install/enable NetworkManager."
fi

if ! command -v hostnamectl >/dev/null 2>&1; then
    fail "hostnamectl command not found."
fi

# --- 驗證函式 ---

validate_ip() {
    local ip=$1
    [[ -z "$ip" ]] && return 1
    local IFS=.
    local -a octets
    read -r -a octets <<< "$ip"
    [ ${#octets[@]} -ne 4 ] && return 1
    for octet in "${octets[@]}"; do
        if [[ ! "$octet" =~ ^(0|[1-9][0-9]*)$ ]] || [ "$octet" -gt 255 ]; then
            return 1
        fi
    done
    return 0
}

mask_to_cidr() {
    local mask=$1
    [[ -z "$mask" ]] && return 1
    # 如果已經是 CIDR prefix (0-32)
    if [[ "$mask" =~ ^[0-9]+$ ]] && [ "$mask" -ge 0 ] && [ "$mask" -le 32 ]; then
        echo "$mask"
        return 0
    fi
    # 如果是 dotted-decimal 子網路遮罩
    local IFS=.
    local -a octets
    read -r -a octets <<< "$mask"
    [ ${#octets[@]} -ne 4 ] && return 1
    for octet in "${octets[@]}"; do
        if [[ ! "$octet" =~ ^(0|[1-9][0-9]*)$ ]] || [ "$octet" -gt 255 ]; then
            return 1
        fi
    done
    
    # 轉換成 2 進位字串 (使用純 Bash 位元運算，免除 bc 依賴與進位轉換 bug)
    local bin=""
    for octet in "${octets[@]}"; do
        local val=$octet
        local b=""
        for ((i=0; i<8; i++)); do
            b=$((val % 2))$b
            val=$((val / 2))
        done
        bin="$bin$b"
    done
    # 驗證是否為合法的遮罩格式 (前面的位元為 1，後面為 0)
    if [[ "$bin" =~ ^1*0*$ ]]; then
        local cidr=${bin%%0*}
        echo "${#cidr}"
        return 0
    fi
    return 1
}


validate_dns() {
    local dns=$1
    [[ -z "$dns" ]] && return 0 # 允許為空
    
    # 暫時關閉 globbing，防止未引號變數展開時發生路徑萬用字元展開
    local -
    set -f
    
    # 以空白或逗號分隔，個別驗證 IP
    local dns_server
    for dns_server in ${dns//,/ }; do
        if ! validate_ip "$dns_server"; then
            return 1
        fi
    done
    return 0
}

validate_hostname() {
    local hn=$1
    [[ -z "$hn" ]] && return 1
    [ ${#hn} -gt 253 ] && return 1
    [[ ! "$hn" =~ ^[a-zA-Z0-9.-]+$ ]] && return 1
    [[ "$hn" =~ ^[.-] ]] && return 1
    [[ "$hn" =~ [.-]$ ]] && return 1
    [[ "$hn" =~ \.\. ]] && return 1
    [[ "$hn" =~ \.- ]] && return 1
    [[ "$hn" =~ -\. ]] && return 1
    
    local IFS=.
    local -a labels
    read -r -a labels <<< "$hn"
    for label in "${labels[@]}"; do
        [ ${#label} -gt 63 ] && return 1
        [[ -z "$label" ]] && return 1
    done
    return 0
}

# --- 動態偵測 OS 名稱 ---
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    SYSTEM_NAME="${PRETTY_NAME:-${NAME:-Linux System}}"
else
    SYSTEM_NAME="Linux System"
fi

# --- 清除畫面，顯示歡迎訊息 ---
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
    ch_device="${devices[0]}"
    echo "Only one ethernet device found. Auto-selected '$ch_device'."
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

# 偵測目前系統的設定作為預設值
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

# IP 驗證迴圈
while true; do
    read -r -e -p "Change [$ch_ipv4] ipv4: " ipv4
    if [ -z "$ipv4" ]; then
        ipv4="$ch_ipv4"
    fi
    if validate_ip "$ipv4"; then
        break
    else
        echo "Error: Invalid IPv4 address format. Please try again."
    fi
done

# Netmask 驗證與轉換迴圈
while true; do
    read -r -e -p "Change [$ch_netmask] netmask (CIDR prefix, e.g. 24, or subnet mask): " netmask_input
    if [ -z "$netmask_input" ]; then
        netmask_input="$ch_netmask"
    fi
    if cidr=$(mask_to_cidr "$netmask_input"); then
        netmask="$cidr"
        break
    else
        echo "Error: Invalid netmask format. Please enter CIDR prefix (0-32) or a valid subnet mask (e.g. 255.255.255.0)."
    fi
done

# Gateway 驗證迴圈
while true; do
    read -r -e -p "Change [$ch_gw4] gateway (press Enter to keep, type 'none' to clear): " gw_input
    if [ -z "$gw_input" ]; then
        gw4="$ch_gw4"
    elif [[ "$gw_input" == "none" ]]; then
        gw4=""
    else
        gw4="$gw_input"
    fi

    if [ -z "$gw4" ] || validate_ip "$gw4"; then
        break
    else
        echo "Error: Invalid gateway IP format. Please try again."
    fi
done

# DNS 驗證迴圈
while true; do
    read -r -e -p "Change [$ch_dns4] dns (space/comma separated, press Enter to keep, type 'none' to clear): " dns_input
    if [ -z "$dns_input" ]; then
        dns4="$ch_dns4"
    elif [[ "$dns_input" == "none" ]]; then
        dns4=""
    else
        dns4="$dns_input"
    fi

    if validate_dns "$dns4"; then
        # 轉換為標準以空白分隔的格式以利 nmcli 解析
        dns4=$(echo "$dns4" | tr ',' ' ' | tr -s ' ')
        dns4="${dns4#"${dns4%%[![:space:]]*}"}"
        dns4="${dns4%"${dns4##*[![:space:]]}"}"
        break
    else
        echo "Error: Invalid DNS IP format. Please try again."
    fi
done

echo
echo "--- Step 3: Configure Hostname ---"
current_hostname=$(hostname)
while true; do
    read -r -e -p "Change [$current_hostname] hostname: " hostname_edit
    if [ -z "$hostname_edit" ]; then
        hostname_edit=$current_hostname
    fi
    if validate_hostname "$hostname_edit"; then
        break
    else
        echo "Error: Invalid hostname format. Please use alphanumeric characters, hyphens (-), and periods (.), and do not start or end with a hyphen or period."
    fi
done
echo

echo "===== Start change nic setting ====="
NM_ARGS=(
    connection.interface-name "$ch_device"
    ipv4.method manual
    ipv4.addresses "$ipv4/$netmask"
    ipv4.ignore-auto-dns yes
    autoconnect yes
)

if [ -n "$gw4" ]; then
    NM_ARGS+=(ipv4.gateway "$gw4")
else
    NM_ARGS+=(ipv4.gateway "")
fi

if [ -n "$dns4" ]; then
    NM_ARGS+=(ipv4.dns "$dns4")
else
    NM_ARGS+=(ipv4.dns "")
fi

run_or_fail nmcli connection modify "$CON_NAME" "${NM_ARGS[@]}"
nmcli connection down "$CON_NAME" >/dev/null 2>&1 || true
run_or_fail nmcli connection up "$CON_NAME"
echo "===== Change nic setting done ====="
echo ""

echo "===== Start change hostname ====="
run_or_fail hostnamectl set-hostname "$hostname_edit"
# 在 /etc/hosts 追加新主機名稱對應
if [ -n "$current_hostname" ]; then
    sed -i -E "/^127\.0\.0\.1/s/([[:space:]]+)${current_hostname}([[:space:]]|$)/\2/g" /etc/hosts
fi
if ! grep -qE "^127\.0\.0\.1.*[[:space:]]${hostname_edit}([[:space:]]|$)" /etc/hosts; then
    sed -i "/^127.0.0.1/s/$/ $hostname_edit/" /etc/hosts
fi
echo "Hostname has been set to: $hostname_edit"
echo "===== Change hostname done ====="

# 首次執行判斷的收尾工作
echo
echo "Setup is complete. Creating flag file to prevent this script from running again."
run_or_fail touch "$FLAG_FILE"

read -r -p "Reboot now to apply all changes? (y/n): " reboot_confirm
if [[ "$reboot_confirm" == "y" || "$reboot_confirm" == "Y" ]]; then
    echo "Rebooting..."
    reboot
fi
