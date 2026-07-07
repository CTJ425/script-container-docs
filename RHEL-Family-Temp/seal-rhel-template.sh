#!/usr/bin/env bash
# =================================================================
# RHEL/Rocky 8.x, 9.x, 10.x VM Sealing and Initialization Script
# - Configures the first-boot interactive setup script on the system
# - Sanitizes all system-specific identities (MAC, UUID, machine-id)
# - Prepares the VM to be converted into a template
# =================================================================

set -u
set -o pipefail

SCRIPT_NAME="$(basename "$0")"
DRY_RUN=0
ASSUME_YES=0
DO_POWEROFF=0

usage() {
  cat <<'USAGE'
Usage:
  sudo ./seal-rhel-template.sh [--dry-run] [--yes] [--poweroff]

Options:
  --dry-run   Show actions without changing the system.
  --yes       Skip the confirmation prompt.
  --poweroff  Power off the VM after cleanup finishes.
  -h, --help  Show this help message.
USAGE
}

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] %q' "$1"
    shift
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
    return 0
  fi

  "$@"
}

run_required() {
  if ! run "$@"; then
    die "Required command failed: $*"
  fi
}

run_shell() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi

  bash -c "$*"
}

run_shell_required() {
  if ! run_shell "$*"; then
    die "Required command failed: $*"
  fi
}

optional_run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    run "$@"
    return 0
  fi

  "$@" || log "Command failed but cleanup will continue: $*"
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "Please run as root, for example: sudo ./$SCRIPT_NAME"
  fi
}

detect_os() {
  [ -r /etc/os-release ] || die "Cannot read /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release

  OS_ID="${ID:-unknown}"
  OS_ID_LIKE="${ID_LIKE:-}"
  OS_NAME="${PRETTY_NAME:-unknown}"
  OS_MAJOR="${VERSION_ID:-}"
  [ -n "$OS_MAJOR" ] || die "Cannot detect OS VERSION_ID from /etc/os-release"
  OS_MAJOR="${OS_MAJOR%%.*}"

  case " $OS_ID $OS_ID_LIKE " in
    *" rhel "*|*" rocky "*|*" centos "*|*" fedora "*) ;;
    *) die "Unsupported OS family: $OS_NAME. This script supports RHEL/Rocky compatible systems only." ;;
  esac

  case "$OS_MAJOR" in
    8|9|10) ;;
    *) die "Unsupported OS version: $OS_NAME. This script supports RHEL/Rocky compatible 8.x, 9.x, and 10.x only." ;;
  esac

  log "Detected OS: $OS_NAME"
}

confirm_run() {
  if [ "$ASSUME_YES" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi

  if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
    die "No interactive terminal available. Re-run with --yes for non-interactive execution."
  fi

  printf 'This will configure first-boot setup and seal this VM. Continue? [y/N] ' > /dev/tty
  if ! read -r answer < /dev/tty; then
    die "Could not read confirmation from /dev/tty. Re-run with --yes for non-interactive execution."
  fi
  case "$answer" in
    y|Y|yes|YES) ;;
    *) die "Cancelled by user." ;;
  esac
}

# --- Embedded Script Writers ---

write_embedded_initial_setup() {
  local target="$1"
  cat << 'EOF' > "$target"
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
if ! grep -q " $hostname_edit" /etc/hosts; then
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
EOF
}

write_embedded_firstboot_profile() {
  local target="$1"
  cat << 'EOF' > "$target"
#!/bin/bash

# Only run if Bash is interactive, root user, standard input is a TTY, and not an SSH session
if [ -n "$BASH_VERSION" ] && [ -z "$SSH_TTY" ] && [ "$(id -u)" -eq 0 ] && [ -t 0 ]; then
    if [ ! -f "/etc/firstboot_completed" ]; then
        /usr/local/bin/initial-setup.sh
    fi
fi
EOF
}

# --- Installation Step ---

install_initial_setup() {
  log "Installing first boot initial-setup script and profile trigger."

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # 如果本地有 standalone 檔案則複製，否則使用內嵌內容
  if [ -f "$script_dir/initial-setup.sh" ] && [ -f "$script_dir/99-firstboot.sh" ]; then
    log "Source files found locally. Copying..."
    run_required cp "$script_dir/initial-setup.sh" /usr/local/bin/initial-setup.sh
    run_required cp "$script_dir/99-firstboot.sh" /etc/profile.d/99-firstboot.sh
  else
    log "Source files not found locally. Writing embedded contents..."
    if [ "$DRY_RUN" -eq 0 ]; then
      write_embedded_initial_setup /usr/local/bin/initial-setup.sh
      write_embedded_firstboot_profile /etc/profile.d/99-firstboot.sh
    else
      log "[dry-run] Write embedded contents to /usr/local/bin/initial-setup.sh and /etc/profile.d/99-firstboot.sh"
    fi
  fi

  run_required chmod +x /usr/local/bin/initial-setup.sh
  run_required chmod +x /etc/profile.d/99-firstboot.sh

  log "Arming setup wizard by ensuring /etc/firstboot_completed flag file does not exist."
  run rm -f /etc/firstboot_completed
}

# --- Sealing Cleanup Steps ---

clean_subscription() {
  if [ "$OS_ID" != "rhel" ]; then
    log "Skip subscription-manager cleanup for non-RHEL OS ID: $OS_ID"
    return 0
  fi

  if ! command -v subscription-manager >/dev/null 2>&1; then
    log "subscription-manager not found; skip registration cleanup."
    return 0
  fi

  log "Cleaning Red Hat subscription registration."
  optional_run subscription-manager unregister
  optional_run subscription-manager remove --all
  optional_run subscription-manager clean
}

clean_network_identity() {
  log "Removing NIC MAC, UUID, and persistent interface mappings."

  # RHEL 8 舊式網路設定清理
  if compgen -G "/etc/sysconfig/network-scripts/ifcfg-*" >/dev/null; then
    run_shell_required "sed -i '/^[[:space:]]*HWADDR=/d;/^[[:space:]]*MACADDR=/d;/^[[:space:]]*UUID=/d' /etc/sysconfig/network-scripts/ifcfg-*"
  fi

  # NetworkManager keyfiles 清理與 UUID 重新產生 (RHEL 9/10)
  if compgen -G "/etc/NetworkManager/system-connections/*.nmconnection" >/dev/null; then
    for f in /etc/NetworkManager/system-connections/*.nmconnection; do
      [ -f "$f" ] || continue
      log "Sanitizing NM connection: $f"
      # 清除裝置特定的參數
      run_shell_required "sed -i '/^[[:space:]]*stable-id=/d;/^[[:space:]]*interface-name=/d;/^[[:space:]]*mac-address=/d;/^[[:space:]]*cloned-mac-address=/d' \"$f\""
      
      # 重新產生 UUID 避免範本複製後的機器 UUID 重疊
      if command -v uuidgen >/dev/null 2>&1; then
        local new_uuid
        new_uuid=$(uuidgen)
        run_shell_required "sed -i '/^[[:space:]]*uuid=/d' \"$f\""
        run_shell_required "sed -i '/^\[connection\]/a uuid=${new_uuid}' \"$f\""
        log "Regenerated UUID for $f: ${new_uuid}"
      else
        # 沒有 uuidgen 則單純清除
        run_shell_required "sed -i '/^[[:space:]]*uuid=/d' \"$f\""
      fi
      run_required chmod 600 "$f"
    done
  fi

  run_required rm -f /etc/udev/rules.d/70-persistent-*
}

clean_hosts_resolver() {
  log "Cleaning hostname entries from /etc/hosts and clearing resolv.conf."
  
  local current_hn
  current_hn=$(hostname)
  
  # 僅從 /etc/hosts 中移除目前的主機名稱對應，保留管理員配置的其他自訂解析規則
  if [ -n "$current_hn" ] && [ "$current_hn" != "localhost" ] && [ "$current_hn" != "localhost.localdomain" ]; then
    run_shell_required "sed -i -E 's/([[:space:]])$current_hn([[:space:]]|$)/\2/g' /etc/hosts"
  fi

  if [ -L /etc/resolv.conf ]; then
    log "/etc/resolv.conf is a symlink; leaving it intact (its target in /run is transient and will clear on reboot)."
  else
    run_shell_required ": > /etc/resolv.conf"
  fi
}

clean_hostname() {
  log "Resetting hostname."
  run_required hostnamectl set-hostname localhost.localdomain
}

clean_ssh_host_keys() {
  log "Removing SSH host keys (will be regenerated on next boot)."
  run_required rm -f /etc/ssh/ssh_host_*
}

clean_machine_id() {
  log "Resetting machine-id for RHEL compatible $OS_MAJOR."

  run_required rm -f /var/lib/dbus/machine-id

  if [ "$OS_MAJOR" = "8" ]; then
    run_shell_required "printf 'uninitialized\n' > /etc/machine-id"
  else
    run_required rm -f /etc/machine-id
    run_shell_required "printf 'uninitialized\n' > /etc/machine-id"
    run_required chmod 644 /etc/machine-id
  fi
}

clean_package_cache() {
  log "Cleaning package manager cache."
  optional_run dnf clean all
}

clean_tmp() {
  log "Cleaning temporary directories /tmp and /var/tmp."
  optional_run find /tmp -mindepth 1 -delete
  optional_run find /var/tmp -mindepth 1 -delete
}

clean_logs() {
  log "Cleaning system logs."
  
  if command -v journalctl >/dev/null 2>&1; then
    log "Vacuuming journalctl logs."
    optional_run journalctl --vacuum-time=1s
  fi

  if [ -d /var/log/journal ]; then
    log "Removing persistent journal logs."
    optional_run rm -rf /var/log/journal/*
  fi

  log "Truncating log files in /var/log."
  find /var/log -type f | while read -r log_file; do
    # 僅針對常規文字日誌進行 truncate
    optional_run truncate -s 0 "$log_file"
  done
}

clean_optional_components() {
  log "Cleaning optional components when installed."

  if command -v rpm >/dev/null 2>&1 && rpm -qa 'katello-ca-consumer*' | grep -q .; then
    optional_run dnf remove -y 'katello-ca-consumer*'
  fi
  optional_run rm -f /etc/rhsm/facts/katello.facts

  if [ -f /etc/iscsi/initiatorname.iscsi ]; then
    optional_run rm -f /etc/iscsi/initiatorname.iscsi
  fi

  if command -v cloud-init >/dev/null 2>&1; then
    optional_run cloud-init clean --logs --seed
  fi

  if command -v insights-client >/dev/null 2>&1; then
    optional_run insights-client --unregister
  fi
}

clean_shell_history() {
  log "Clearing shell history files."

  clear_bash_history() {
    history_file="$1"

    [ -e "$history_file" ] || return 0
    optional_run rm -f "$history_file"
  }

  clear_history_dir() {
    home_dir="$1"

    [ -n "$home_dir" ] || return 0
    [ -d "$home_dir" ] || return 0

    case "$home_dir" in
      /|/bin|/boot|/dev|/etc|/proc|/run|/sbin|/sys|/tmp|/usr|/var)
        log "Skip suspicious home directory while clearing history: $home_dir"
        return 0
        ;;
    esac

    clear_bash_history "$home_dir/.bash_history"
  }

  clear_history_dir /root

  if command -v getent >/dev/null 2>&1; then
    getent passwd | while IFS=: read -r _ _ uid _ _ home_dir _; do
      case "$uid" in
        ''|*[!0-9]*) continue ;;
      esac

      [ "$uid" -ge 1000 ] || continue
      clear_history_dir "$home_dir"
    done
  elif [ -d /home ]; then
    find /home -mindepth 2 -maxdepth 2 -name .bash_history -type f | while IFS= read -r history_file; do
      clear_bash_history "$history_file"
    done
  fi
}

# --- Main Logic ---

main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --yes) ASSUME_YES=1 ;;
      --poweroff) DO_POWEROFF=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done

  require_root
  detect_os
  confirm_run

  # 1. 優先執行 initial-setup 設定
  install_initial_setup

  # 2. 隨後執行 Seal VM 清理工作
  clean_subscription
  clean_network_identity
  clean_hosts_resolver
  clean_hostname
  clean_ssh_host_keys
  clean_machine_id
  clean_package_cache
  clean_tmp
  clean_logs
  clean_optional_components
  clean_shell_history

  log "Seal and setup configuration completed successfully."
  log "Shut down this VM before converting it to a template."
  log "--------------------------------------------------------"
  log "NOTE: To prevent your current shell history from being"
  log "written back to disk on logout, please exit using:"
  log "  history -c && history -w && exit"
  log "Or force-terminate the parent shell:"
  log "  kill -9 \$PPID"
  log "--------------------------------------------------------"

  if [ "$DO_POWEROFF" -eq 1 ]; then
    log "Powering off VM."
    run_required systemctl poweroff
  fi
}

main "$@"
