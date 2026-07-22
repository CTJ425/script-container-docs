# 腳本修復方案與修正程式碼 (Fixes & Complete Refactored Code)

> **建立時間**：2026-07-22  
> **說明**：本文件提供全專案腳本之優化修正完整代碼與修改細節對照，供維運人員直接替換或整合使用。

---

## 1. 修正一：RHEL Family 首次開機設定腳本 (Refactored `initial-setup.sh`)

### 🛠️ 修正重點摘要
1. 加入完整 IP, CIDR Mask, Gateway, DNS, Hostname 格式正則驗證迴圈。
2. 導入 `mask_to_cidr` 純 Bash 位元運算轉換函式。
3. 採用 `NM_ARGS` 陣列傳參，徹底解決 `nmcli` 空變數位置錯位 Bug。
4. 增加 `/run/initial-setup.lock` 併發鎖防護。
5. 單一網卡自動選取，無需手動選擇。
6. 設定 Hostname 後同步修剪並更新 `/etc/hosts` 的 `127.0.0.1` 條目。
7. 增加非互動 Terminal 檢查 (`[ -t 0 ]`) 避免腳本卡死。

### 📄 完整重構代碼 (可適用於 `Inital-setup/` 與 `RHEL-Family-Temp/`)

```bash
#!/usr/bin/env bash
# =================================================================
# Enterprise Production-Grade First Boot Initial Setup Script
# - Auto-selects single NIC; provides robust interactive validation
# - Atomic execution lock prevents race conditions
# - Safely updates NetworkManager and /etc/hosts
# =================================================================

set -o pipefail

FLAG_FILE="/etc/firstboot_completed"
LOCK_DIR="/run/initial-setup.lock"

fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

run_or_fail() {
    "$@" || fail "Command failed: $*"
}

# 1. 檢查旗標檔
if [ -f "$FLAG_FILE" ]; then
    exit 0
fi

# 2. 檢查 root 權限
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    fail "This script must be run as root."
fi

# 3. 併發互斥鎖防護
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "[WARN] Another instance of initial-setup is running. Exiting."
    exit 0
fi
trap 'rm -rf "$LOCK_DIR"' EXIT

# 4. 必要指令檢查
for cmd in nmcli hostnamectl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        fail "Required command '$cmd' not found."
    fi
done

# 5. 驗證函式庫
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
    if [[ "$mask" =~ ^[0-9]+$ ]] && [ "$mask" -ge 0 ] && [ "$mask" -le 32 ]; then
        echo "$mask"
        return 0
    fi
    local IFS=.
    local -a octets
    read -r -a octets <<< "$mask"
    [ ${#octets[@]} -ne 4 ] && return 1
    for octet in "${octets[@]}"; do
        if [[ ! "$octet" =~ ^(0|[1-9][0-9]*)$ ]] || [ "$octet" -gt 255 ]; then
            return 1
        fi
    done
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
    if [[ "$bin" =~ ^1*0*$ ]]; then
        local cidr=${bin%%0*}
        echo "${#cidr}"
        return 0
    fi
    return 1
}

validate_dns() {
    local dns=$1
    [[ -z "$dns" ]] && return 0
    local -f
    set -f
    local dns_server
    for dns_server in ${dns//,/ }; do
        if ! validate_ip "$dns_server"; then
            set +f
            return 1
        fi
    done
    set +f
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
    return 0
}

# 6. 動態 OS 偵測
if [ -f /etc/os-release ]; then
    . /etc/os-release
    SYSTEM_NAME="${PRETTY_NAME:-${NAME:-Linux System}}"
else
    SYSTEM_NAME="Linux System"
fi

clear
echo "=========================================================="
echo " Welcome to $SYSTEM_NAME Initial Setup"
echo " This script will run only once on the first root login."
echo "=========================================================="
echo

# 7. 網卡選取
echo "--- Step 1: Select Network Interface ---"
mapfile -t devices < <(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2 == "ethernet" {print $1}')
device_count=${#devices[@]}

if [ "$device_count" -eq 0 ]; then
    fail "No ethernet devices found. Aborting."
elif [ "$device_count" -eq 1 ]; then
    ch_device=${devices[0]}
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
echo "Selected interface: $ch_device"
echo

CON_NAME=$(nmcli -g GENERAL.CONNECTION device show "$ch_device" 2>/dev/null | head -n 1)
if [ "$CON_NAME" = "--" ] || [ -z "$CON_NAME" ]; then
    CON_NAME=$(nmcli -t -f NAME,DEVICE connection show | awk -F: -v dev="$ch_device" '$2 == dev {print $1; exit}')
fi
if [ -z "$CON_NAME" ]; then
    CON_NAME="$ch_device"
    echo "No existing connection profile found for '$ch_device'. Creating '$CON_NAME'."
    run_or_fail nmcli connection add type ethernet ifname "$ch_device" con-name "$CON_NAME" autoconnect yes
fi

# 8. 互動輸入與驗證迴圈
full_address=$(nmcli -g IP4.ADDRESS device show "$ch_device" 2>/dev/null | head -n 1 | cut -d'[' -f1)
[ -z "$full_address" ] && full_address=$(nmcli -g ipv4.addresses connection show "$CON_NAME" 2>/dev/null | head -n 1)

ch_ipv4=$(echo "$full_address" | cut -d'/' -f1)
ch_netmask=$(echo "$full_address" | cut -s -d'/' -f2)
ch_gw4=$(nmcli -g IP4.GATEWAY device show "$ch_device" 2>/dev/null | head -n 1)
[ -z "$ch_gw4" ] && ch_gw4=$(nmcli -g ipv4.gateway connection show "$CON_NAME" 2>/dev/null | head -n 1)
ch_dns4=$(nmcli -g IP4.DNS device show "$ch_device" 2>/dev/null | paste -sd ' ' -)
[ -z "$ch_dns4" ] && ch_dns4=$(nmcli -g ipv4.dns connection show "$CON_NAME" 2>/dev/null | paste -sd ' ' -)

while true; do
    read -r -e -p "Change [$ch_ipv4] IPv4 address: " ipv4
    ipv4=${ipv4:-$ch_ipv4}
    validate_ip "$ipv4" && break || echo "Invalid IPv4 format. Try again."
done

while true; do
    read -r -e -p "Change [$ch_netmask] Subnet Mask / CIDR (e.g. 24 or 255.255.255.0): " netmask_input
    netmask_input=${netmask_input:-$ch_netmask}
    if cidr=$(mask_to_cidr "$netmask_input"); then
        netmask="$cidr"
        break
    else
        echo "Invalid Subnet Mask / CIDR prefix. Try again."
    fi
done

while true; do
    read -r -e -p "Change [$ch_gw4] Gateway (press Enter to keep, 'none' to clear): " gw_input
    if [ -z "$gw_input" ]; then
        gw4="$ch_gw4"
    elif [ "$gw_input" = "none" ]; then
        gw4=""
    else
        gw4="$gw_input"
    fi
    [ -z "$gw4" ] || validate_ip "$gw4" && break || echo "Invalid Gateway IP format. Try again."
done

while true; do
    read -r -e -p "Change [$ch_dns4] DNS (space/comma separated, 'none' to clear): " dns_input
    if [ -z "$dns_input" ]; then
        dns4="$ch_dns4"
    elif [ "$dns_input" = "none" ]; then
        dns4=""
    else
        dns4="$dns_input"
    fi
    if validate_dns "$dns4"; then
        dns4=$(echo "$dns4" | tr ',' ' ' | tr -s ' ')
        dns4=${dns4# }
        dns4=${dns4% }
        break
    else
        echo "Invalid DNS format. Try again."
    fi
done

echo
echo "--- Step 3: Configure Hostname ---"
current_hostname=$(hostname)
while true; do
    read -r -e -p "Change [$current_hostname] Hostname: " hostname_edit
    hostname_edit=${hostname_edit:-$current_hostname}
    validate_hostname "$hostname_edit" && break || echo "Invalid Hostname format. Try again."
done

# 9. 套用 NetworkManager 設定
echo "===== Start changing NIC setting ====="
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
echo "===== NIC setting updated successfully ====="
echo

# 10. 套用 Hostname 並修剪 /etc/hosts
echo "===== Setting Hostname ====="
run_or_fail hostnamectl set-hostname "$hostname_edit"

# 清理 hosts 中的舊主機名並追加新名稱
if grep -q "^127\.0\.0\.1" /etc/hosts; then
    sed -i "/^127\.0\.0\.1/s/[[:space:]]\+${current_hostname}\b//g" /etc/hosts
    if ! grep -q " ${hostname_edit}\b" /etc/hosts; then
        sed -i "/^127\.0\.0\.1/s/$/ ${hostname_edit}/" /etc/hosts
    fi
fi
echo "Hostname set to: $hostname_edit"
echo "===== Hostname updated successfully ====="

# 11. 完成收尾
echo
run_or_fail touch "$FLAG_FILE"
echo "Setup completed successfully."

if [ -t 0 ]; then
    read -r -p "Reboot now to apply all changes? (y/N): " reboot_confirm
    if [[ "${reboot_confirm,,}" == "y" || "${reboot_confirm,,}" == "yes" ]]; then
        echo "Rebooting system..."
        reboot
    fi
fi
```

---

## 2. 修正二：Profile.d 開機觸發腳本 (Refactored `99-firstboot.sh`)

### 📄 完整重構代碼

```bash
#!/usr/bin/env bash
# /etc/profile.d/99-firstboot.sh

# 支援 SSH 登入與 Console 登入，非互動 Term 不執行
if [ -n "$BASH_VERSION" ] && [ "$(id -u)" -eq 0 ] && [ -t 0 ]; then
    if [ ! -f "/etc/firstboot_completed" ] && [ -x "/usr/local/bin/initial-setup.sh" ]; then
        /usr/local/bin/initial-setup.sh
    fi
fi
```

---

## 3. 修正三：RHEL VM 範本清理工具 (Refactored `seal-rhel-template.sh`)

### 📄 修正片段與重構細節

1. **修正 `/etc/hosts` 清理邏輯（不重寫全檔）**：
   ```bash
   clean_hosts_resolver() {
     log "Cleaning hostname entries from /etc/hosts and resetting /etc/resolv.conf."
     current_hn=$(hostname)
     if [ -f /etc/hosts ]; then
       sed -i "/^127\.0\.0\.1/s/[[:space:]]\+${current_hn}\b//g" /etc/hosts
     fi
     if [ -L /etc/resolv.conf ]; then
       run_required rm -f /etc/resolv.conf
       run_required touch /etc/resolv.conf
       run_required chmod 644 /etc/resolv.conf
     else
       run_shell_required ": > /etc/resolv.conf"
     fi
   }
   ```

2. **修正 Machine-ID 清理邏輯（符合 systemd 規範）**：
   ```bash
   clean_machine_id() {
     log "Resetting machine-id for systemd compliance."
     run_required rm -f /var/lib/dbus/machine-id
     run_required rm -f /etc/machine-id
     run_shell_required ": > /etc/machine-id"
     run_required chmod 644 /etc/machine-id
   }
   ```

3. **擴充 OS 相容性**：
   ```bash
   case " $OS_ID $OS_ID_LIKE " in
     *" rhel "*|*" rocky "*|*" almalinux "*|*" centos "*|*" fedora "*) ;;
     *) die "Unsupported OS family: $OS_NAME." ;;
   esac
   ```

---

## 4. 修正四：Proxmox VE ISO 符號連結同步腳本 (Refactored `pve_link_iso.sh`)

### 📄 完整重構代碼

```bash
#!/usr/bin/env bash
# =================================================================
# Proxmox VE ISO Symlink Sync Script
# - Fixes subshell variable scope issue
# - Correctly handles dangling symlinks and file collisions
# =================================================================

set -euo pipefail

SOURCE_DIR="${1:-/mnt/pve/ISO}"
TARGET_DIR="${2:-/mnt/pve/ISO/template/iso}"

echo "============================================="
echo "開始同步 ISO 檔案連結..."
echo "來源目錄 (Source): $SOURCE_DIR"
echo "目標目錄 (Target): $TARGET_DIR"
echo "============================================="

if [ ! -d "$SOURCE_DIR" ]; then
    echo "[錯誤] 來源目錄 '$SOURCE_DIR' 不存在。" >&2
    exit 1
fi

if [ ! -d "$TARGET_DIR" ]; then
    echo "[錯誤] 目標目錄 '$TARGET_DIR' 不存在。" >&2
    exit 1
fi

# 1. 清理目標目錄中所有無效或舊有 ISO 連結
echo -n "正在清理舊的 ISO 軟連結..."
find "$TARGET_DIR" -maxdepth 1 -type l -iname "*.iso" -delete
echo " 完成。"

# 2. 掃描並建立新連結 (進程替換 Avoiding Subshell Scope Bug)
echo "正在掃描來源目錄並建立新連結..."
COUNT=0
FAILED=0

while IFS= read -r -d $'\0' iso_file; do
    filename=$(basename "$iso_file")
    target_file="${TARGET_DIR}/${filename}"

    # 檢查是否為無效軟連結或已存在目標檔
    if [ -L "$target_file" ] && [ ! -e "$target_file" ]; then
        rm -f "$target_file"
    fi

    if [ ! -e "$target_file" ]; then
        if ln -s "$iso_file" "$target_file"; then
            echo "  -> 已連結: $filename"
            ((COUNT+=1))
        else
            echo "  -> 連結失敗: $filename"
            ((FAILED+=1))
        fi
    else
        echo "  -> 跳過 (檔案已存在): $filename"
    fi
done < <(
    find "$SOURCE_DIR" \
        -path "$TARGET_DIR" -prune -o \
        -type d -name "@eaDir" -prune -o \
        -type f -iname "*.iso" \
        -print0
)

echo "============================================="
echo "處理完成！總共建立了 $COUNT 個新的符號連結。"
if [ "$FAILED" -gt 0 ]; then
    echo "[警告] 有 $FAILED 個 ISO 連結建立失敗，請檢查權限。"
fi
echo "============================================="
```

---

## 5. 修正五：Docker Compose 彈性部署檔 (`docker-compose.yml`)

### 📄 重構版本 (支援可選 GPU 與明確版本標籤)

```yaml
services:
  ollama:
    container_name: ollama
    restart: unless-stopped
    image: ollama/ollama:0.5.7
    ports:
      - "11434:11434"
    volumes:
      - ollama-data:/root/.ollama
    # 若無 NVIDIA GPU 可直接註解以下 deploy 區塊
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]

  open-webui:
    container_name: openwebui
    restart: unless-stopped
    image: ghcr.io/open-webui/open-webui:0.5.9
    ports:
      - "8080:8080"
    volumes:
      - openwebui-data:/app/backend/data
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434

volumes:
  ollama-data:
  openwebui-data:
```
