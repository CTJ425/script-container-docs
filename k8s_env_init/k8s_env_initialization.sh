#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# Check if the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo." >&2
    exit 1
fi

# Global variables for OS detection
OS_FAMILY=""
OS_NAME=""
OS_VERSION=""
OS_ID=""
OS_ID_LIKE=""

get_os_major_version() {
    if [[ "$OS_VERSION" =~ ^([0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

is_rhel_compatible_10_or_newer() {
    local major_version
    major_version="$(get_os_major_version)"

    [[ "$OS_ID" =~ ^(rhel|rocky|almalinux|centos)$ ]] &&
        [ -n "$major_version" ] &&
        [ "$major_version" -ge 10 ]
}

# Function: Detect Operating System
detect_os() {
    echo "=== Detecting Operating System ==="
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        OS_NAME="${NAME:-Unknown Linux}"
        OS_VERSION="${VERSION_ID:-Unknown}"
        OS_ID="${ID:-unknown}"
        OS_ID_LIKE="${ID_LIKE:-}"
        if [[ "$OS_ID" =~ ^(rhel|rocky|almalinux|centos|fedora)$ ]] || [[ "$OS_ID_LIKE" =~ (rhel|centos|fedora) ]]; then
            OS_FAMILY="rhel"
        elif [[ "$OS_ID" =~ ^(ubuntu|debian|kali|linuxmint)$ ]] || [[ "$OS_ID_LIKE" =~ (debian|ubuntu) ]]; then
            OS_FAMILY="debian"
        else
            OS_FAMILY="unknown"
        fi
    else
        OS_FAMILY="unknown"
        OS_NAME="Unknown Linux"
        OS_VERSION="Unknown"
    fi
    echo "OS Detected: $OS_NAME ($OS_VERSION) - Family: $OS_FAMILY"
    if [ "$OS_FAMILY" = "unknown" ]; then
        echo "Unsupported Linux distribution. Supported families: RHEL/Rocky/Alma/CentOS/Fedora and Debian/Ubuntu." >&2
        exit 1
    fi
    echo ""
}

# Function: Disable Firewall
disable_firewall() {
    echo "=== 1. Disabling Firewall ==="
    case "$OS_FAMILY" in
        debian)
            echo "Detected Debian/Ubuntu family. Disabling ufw..."
            systemctl stop ufw || echo "ufw already stopped or not found."
            systemctl disable ufw || echo "ufw already disabled or not found."
            echo "Firewall (ufw) has been stopped and disabled."
            ;;
        rhel)
            echo "Detected RHEL/Rocky family. Disabling firewalld..."
            systemctl stop firewalld || echo "firewalld already stopped or not found."
            systemctl disable firewalld || echo "firewalld already disabled or not found."
            echo "Firewall (firewalld) has been stopped and disabled."
            ;;
        *)
            echo "Unsupported OS family: $OS_FAMILY" >&2
            exit 1
            ;;
    esac
    echo ""
}

# Function: Disable SELinux
disable_selinux() {
    if [ "$OS_FAMILY" = "rhel" ]; then
        local selinux_target="disabled"

        echo "=== 2. Configuring SELinux ==="
        if is_rhel_compatible_10_or_newer; then
            echo "RHEL-compatible 10+ detected. Setting SELinux to permissive instead of disabled."
            selinux_target="permissive"
        else
            # Update kernel arguments via grubby if grubby is available
            if command -v grubby >/dev/null 2>&1; then
                grubby --update-kernel ALL --args selinux=0
                echo "Updated kernel arguments via grubby to include 'selinux=0'."
            else
                echo "grubby not found. Skipping grubby update."
            fi
        fi

        # Update /etc/selinux/config if it exists
        if [ -f /etc/selinux/config ]; then
            sed -i "s/^SELINUX=.*/SELINUX=$selinux_target/g" /etc/selinux/config || true
            echo "Updated /etc/selinux/config to SELINUX=$selinux_target."
        fi
        echo "SELinux settings updated. A reboot is required to fully apply changes."
        echo ""
    else
        echo "=== 2. Skipping SELinux Disabling ==="
        echo "System is Debian/Ubuntu family (uses AppArmor, which is natively supported by Kubernetes)."
        echo ""
    fi
}

# Function: Disable Swap
disable_swap() {
    echo "=== 3. Disabling Swap ==="
    # Turn off all running swap partitions
    swapoff -a
    
    # Comment out the swap line in /etc/fstab precisely using sed
    # -i.bak: Modify the file in-place and create a .bak backup
    # '/\s+swap\s+/' finds the line where the filesystem type is swap
    # s/^#*/#/ ensures the line starts with exactly one #, making the script idempotent
    sed -r -i.bak '/\s+swap\s+/s/^#*/#/' /etc/fstab
    
    echo "Swap has been disabled and commented out in /etc/fstab."
    echo ""
}

# Function: Load Kernel Modules
load_kernel_modules() {
    echo "=== 4. Loading Kernel Modules ==="
    # Create a configuration file to load modules on boot
    cat > /etc/modules-load.d/crio.conf <<EOF
overlay
br_netfilter
EOF

    # Load the modules immediately
    modprobe overlay
    modprobe br_netfilter
    echo "Kernel modules overlay and br_netfilter have been loaded."
    echo ""
}

# Function: Configure Kernel Parameters
setup_kernel_params() {
    echo "=== 5. Configuring Kernel Parameters (sysctl) ==="
    # Create the kernel parameters configuration file for K8s
    cat > /etc/sysctl.d/99-kubernetes-cri.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

    # Apply sysctl settings without rebooting
    sysctl --system
    echo "Kernel parameters have been set and loaded."
    echo ""
}

print_check() {
    local status="$1"
    local item="$2"
    local detail="$3"

    printf '[%s] %s - %s\n' "$status" "$item" "$detail"
}

verify_firewall() {
    local service_name
    local active_state
    local enabled_state

    if [ "$OS_FAMILY" = "debian" ]; then
        service_name="ufw"
    else
        service_name="firewalld"
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        print_check "WARN" "Firewall service" "systemctl not found; cannot verify $service_name."
        return
    fi

    active_state="$(systemctl is-active "$service_name" 2>/dev/null || true)"
    enabled_state="$(systemctl is-enabled "$service_name" 2>/dev/null || true)"

    if [[ "$active_state" =~ ^(inactive|failed|unknown)$ ]] &&
        [[ "$enabled_state" =~ ^(disabled|masked|not-found|)$ ]]; then
        print_check "OK" "Firewall service ($service_name)" "inactive and not enabled on boot."
    else
        print_check "WARN" "Firewall service ($service_name)" "active=$active_state, enabled=$enabled_state."
    fi
}

verify_security_module() {
    if [ "$OS_FAMILY" = "debian" ]; then
        print_check "OK" "Security module" "SELinux skipped; AppArmor can remain enabled for Kubernetes."
        return
    fi

    local expected_selinux
    local config_selinux="missing"
    local runtime_selinux="unknown"

    if is_rhel_compatible_10_or_newer; then
        expected_selinux="permissive"
    else
        expected_selinux="disabled"
    fi

    if [ -f /etc/selinux/config ]; then
        config_selinux="$(awk -F= '/^SELINUX=/{print $2; exit}' /etc/selinux/config)"
    fi

    if command -v getenforce >/dev/null 2>&1; then
        runtime_selinux="$(getenforce 2>/dev/null || true)"
    fi

    if [ "$config_selinux" = "$expected_selinux" ]; then
        print_check "OK" "SELinux config" "SELINUX=$config_selinux."
    else
        print_check "WARN" "SELinux config" "expected SELINUX=$expected_selinux, current SELINUX=$config_selinux."
    fi

    if [ "$expected_selinux" = "disabled" ]; then
        if command -v grubby >/dev/null 2>&1 &&
            grubby --info=ALL 2>/dev/null | grep -q 'selinux=0'; then
            print_check "OK" "SELinux kernel argument" "selinux=0 found; reboot is required to apply fully."
        elif command -v grubby >/dev/null 2>&1; then
            print_check "WARN" "SELinux kernel argument" "selinux=0 not found in grubby output."
        else
            print_check "WARN" "SELinux kernel argument" "grubby not found; kernel argument was not verified."
        fi
    else
        print_check "OK" "SELinux kernel argument" "RHEL-compatible 10+ uses permissive mode; selinux=0 is not required."
    fi

    print_check "INFO" "SELinux runtime" "current runtime state: $runtime_selinux; reboot may be required."
}

verify_swap() {
    if swapon --noheadings --show 2>/dev/null | grep -q .; then
        print_check "WARN" "Swap runtime" "swap is still active."
    else
        print_check "OK" "Swap runtime" "no active swap detected."
    fi

    if [ ! -f /etc/fstab ]; then
        print_check "WARN" "Swap fstab" "/etc/fstab not found."
    elif awk '$1 !~ /^#/ && $3 == "swap" {found=1} END {exit found ? 0 : 1}' /etc/fstab; then
        print_check "WARN" "Swap fstab" "uncommented swap entry still exists."
    else
        print_check "OK" "Swap fstab" "no uncommented swap entry detected."
    fi
}

verify_kernel_modules() {
    local module
    local config_ok="yes"

    for module in overlay br_netfilter; do
        if lsmod | awk '{print $1}' | grep -qx "$module"; then
            print_check "OK" "Kernel module ($module)" "loaded."
        else
            print_check "WARN" "Kernel module ($module)" "not loaded."
        fi

        if ! grep -qx "$module" /etc/modules-load.d/crio.conf 2>/dev/null; then
            config_ok="no"
        fi
    done

    if [ "$config_ok" = "yes" ]; then
        print_check "OK" "Kernel module boot config" "/etc/modules-load.d/crio.conf contains overlay and br_netfilter."
    else
        print_check "WARN" "Kernel module boot config" "/etc/modules-load.d/crio.conf is missing expected modules."
    fi
}

verify_sysctl_params() {
    local key
    local value
    local config_file="/etc/sysctl.d/99-kubernetes-cri.conf"

    for key in net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward net.bridge.bridge-nf-call-ip6tables; do
        if value="$(sysctl -n "$key" 2>/dev/null)" && [ "$value" = "1" ]; then
            print_check "OK" "Sysctl runtime ($key)" "value=$value."
        else
            print_check "WARN" "Sysctl runtime ($key)" "expected value=1, current value=${value:-unavailable}."
        fi
    done

    if [ -f "$config_file" ] &&
        grep -q '^net.bridge.bridge-nf-call-iptables[[:space:]]*=[[:space:]]*1$' "$config_file" &&
        grep -q '^net.ipv4.ip_forward[[:space:]]*=[[:space:]]*1$' "$config_file" &&
        grep -q '^net.bridge.bridge-nf-call-ip6tables[[:space:]]*=[[:space:]]*1$' "$config_file"; then
        print_check "OK" "Sysctl config" "$config_file contains required Kubernetes parameters."
    else
        print_check "WARN" "Sysctl config" "$config_file is missing one or more required parameters."
    fi
}

verify_setup() {
    echo "=== Verification Summary ==="
    echo "Detected OS: $OS_NAME ($OS_VERSION)"
    echo "OS ID: $OS_ID"
    echo "OS family: $OS_FAMILY"
    echo ""

    verify_firewall
    verify_security_module
    verify_swap
    verify_kernel_modules
    verify_sysctl_params
    echo ""
}

# Main function
main() {
    detect_os
    disable_firewall
    disable_selinux
    disable_swap
    load_kernel_modules
    setup_kernel_params
    verify_setup

    echo "Setup is complete."
    
    local reboot_prompt="Reboot now to apply all changes? (y/n): "
    if [ "$OS_FAMILY" = "rhel" ]; then
        reboot_prompt="Reboot now to apply all changes (especially for SELinux)? (y/n): "
    fi

    read -r -p "$reboot_prompt" reboot_confirm
    # Convert input to lowercase for comparison
    if [[ "${reboot_confirm,,}" == "y" || "${reboot_confirm,,}" == "yes" ]]; then
        echo "Rebooting..."
        reboot
    else
        echo "Reboot cancelled. Please remember to reboot manually later if needed."
    fi
}

# Execute the main function
main
