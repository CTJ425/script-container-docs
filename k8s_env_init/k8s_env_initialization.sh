#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# Check if the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo." >&2
    exit 1
fi

# Function: Disable Firewall
disable_firewall() {
    echo "=== 1. Disabling Firewall (firewalld) ==="
    # Stop the service now
    # Use || true to prevent 'set -e' from exiting if already stopped or not found
    systemctl stop firewalld || echo "firewalld already stopped or not found."
    # Disable the service on boot
    systemctl disable firewalld || echo "firewalld already disabled or not found."
    echo "Firewall (firewalld) has been stopped and disabled."
    echo ""
}

# Function: Disable SELinux
disable_selinux() {
    echo "=== 2. Disabling SELinux ==="
    # Update kernel arguments via grubby to disable SELinux on next boot
    grubby --update-kernel ALL --args selinux=0
    echo "Updated kernel arguments via grubby to include 'selinux=0'."
    echo "SELinux will be fully disabled upon reboot."
    echo ""
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

# Main function
main() {
    disable_firewall
    disable_selinux
    disable_swap
    load_kernel_modules
    setup_kernel_params

    echo "Setup is complete."
    # Updated prompt to emphasize reboot is necessary for SELinux
    read -r -p "Reboot now to apply all changes (especially for SELinux)? (y/n): " reboot_confirm
    # Convert input to lowercase for comparison
    if [[ "${reboot_confirm,,}" == "y" || "${reboot_confirm,,}" == "yes" ]]; then
        echo "Rebooting..."
        reboot
    else
        echo "Reboot cancelled. Please remember to reboot manually later for SELinux changes to take effect."
    fi
}

# Execute the main function
main
