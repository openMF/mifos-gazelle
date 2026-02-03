#!/bin/bash
#
# Note this script is untested but is here to document and ideally automate the steps
# needed to set up port forwarding for a Ubuntu 24.04 client VM running on macOS (host) with VMware Fusion.
# this is needed to access the k3s services endpoints running in the VM from the host macOS.
# note that it does assume that port 443 is availab on the host macOS

# VMware Fusion NAT Setup Script
# Author: Gemini
# Date: October 2025
#
# PURPOSE:
# This script applies the proven static IP and port forwarding configuration
# for your Ubuntu k3s VM on the macOS host running VMware Fusion.
#
# It ensures the VM (172.16.211.100) is accessible via Mac localhost on the
# following ports, matching your successful configuration:
#   - Mac Port 8080 -> VM Port 80 (HTTP)
#   - Mac Port 443 -> VM Port 443 (HTTPS)
#   - Mac Port 8000 -> VM Port 8000 (Custom)
#
# INSTRUCTIONS:
# 1. Ensure VMware Fusion is COMPLETELY SHUT DOWN before running this script.
#
# 2. *** HOW TO FIND THE VM MAC ADDRESS (Inside the Ubuntu VM) ***
#    a. Log into your Ubuntu VM.
#    b. Run the command: ip a
#    c. Look for the active network interface (e.g., eth0 or ens33).
#    d. The "link/ether" value is the MAC address you need (e.g., 00:0C:29:A1:B2:C3).
#
# 3. Make the script executable: chmod +x setup_vmware_nat.sh
# 4. Run the script using sudo: sudo ./setup_vmware_nat.sh
# 5. Enter the current MAC address of your Ubuntu VM when prompted.
# 6. When finished, restart VMware Fusion and your VM.
# 7. If the hosts file was updated, you may need to flush the DNS cache:
#    dscacheutil -flushcache; sudo killall -HUP mDNSResponder
#

# --- Configuration Variables ---

# The static IP we successfully assigned to the VM using the DHCP lease.
VM_STATIC_IP="172.16.211.100"

# The hostname used in the hosts file and DHCP lease description
VM_HOSTNAME="mifos.mifos.gazelle.test"

# Root path for VMware Fusion network configuration files
VMWARE_CONFIG_PATH="/Library/Preferences/VMware Fusion"

# Specific file paths within vmnet8 (the NAT network)
DHCPD_CONF="${VMWARE_CONFIG_PATH}/vmnet8/dhcpd.conf"
NAT_CONF="${VMWARE_CONFIG_PATH}/vmnet8/nat.conf"
HOSTS_FILE="/etc/hosts"

# --- Function Definitions ---

# Create a timestamped backup of a file
create_backup() {
    local FILE_PATH="$1"
    local BACKUP_FILE="${FILE_PATH}.bak.$(date +%Y%m%d%H%M%S)"

    if [ -f "$FILE_PATH" ]; then
        cp "$FILE_PATH" "$BACKUP_FILE"
        echo "[INFO] Backup created: $BACKUP_FILE"
    else
        echo "[WARN] File not found, skipping backup: $FILE_PATH"
    fi
}

# --- Main Script Execution ---

echo "--- VMware Fusion NAT Configuration Helper ---"

# 1. Get VM MAC Address from User
echo ""
echo "!!! REFERENCE INSTRUCTIONS ABOVE (Step 2) TO FIND THE MAC ADDRESS !!!"
read -p ">> Enter the current MAC address of your VM (e.g., 00:0C:29:A1:B2:C3): " VM_MAC_ADDRESS

if [ -z "$VM_MAC_ADDRESS" ]; then
    echo "[ERROR] MAC address cannot be empty. Exiting."
    exit 1
fi

echo ""
echo "[STATUS] Target VM Static IP: ${VM_STATIC_IP}"
echo "[STATUS] Target VM MAC Address: ${VM_MAC_ADDRESS}"
echo ""

# 2. Update DHCP Configuration (Static IP Lease)
echo "--- 1. Updating DHCP Configuration (${DHCPD_CONF}) ---"
create_backup "$DHCPD_CONF"

# Use sed to remove any previous instance of the custom lease block
echo "[INFO] Cleaning up old lease blocks..."
sed -i '' '/# START_CUSTOM_VM_LEASE/,/# END_CUSTOM_VM_LEASE/d' "$DHCPD_CONF"

echo "[INFO] Appending new static lease block..."

# Use a HEREDOC to cleanly append the lease block
cat << EOF >> "$DHCPD_CONF"
# START_CUSTOM_VM_LEASE (Managed by setup_vmware_nat.sh)
host ${VM_HOSTNAME} {
    hardware ethernet ${VM_MAC_ADDRESS};
    fixed-address ${VM_STATIC_IP};
}
# END_CUSTOM_VM_LEASE
EOF
echo "[SUCCESS] Static IP lease added for ${VM_STATIC_IP}."


# 3. Update NAT Configuration (Port Forwarding)
echo ""
echo "--- 2. Updating NAT Configuration (${NAT_CONF}) ---"
create_backup "$NAT_CONF"

# Find and replace the [incomingtcp] block with the required forwards.
# NOTE: This replaces the entire block to ensure consistency.
echo "[INFO] Replacing [incomingtcp] section with required forwards..."

# 3a. Create the new [incomingtcp] block content using a temporary file
TEMP_NAT_BLOCK=$(mktemp)
cat << EOF > "$TEMP_NAT_BLOCK"
[incomingtcp]
# Port Forwarding Rules for k3s VM: ${VM_STATIC_IP}
# Format: <Mac Port> = <VM Static IP>:<VM Port>
#
# Mac Port 8080 (non-privileged) -> VM Port 80 (HTTP)
8080 = ${VM_STATIC_IP}:80
# Mac Port 443 (standard HTTPS) -> VM Port 443 (HTTPS)
443 = ${VM_STATIC_IP}:443
# Mac Port 8000 (custom) -> VM Port 8000
8000 = ${VM_STATIC_IP}:8000

EOF

# 3b. Use awk to replace the old [incomingtcp] block with the new content
# This is more complex but safer than manual text injection for NAT.CONF
awk '
    BEGIN { in_incomingtcp = 0; }
    /\[incomingtcp\]/ {
        in_incomingtcp = 1;
        system("cat " ENVIRON["TEMP_NAT_BLOCK"]);
        next;
    }
    /^\[/ { in_incomingtcp = 0; }
    !in_incomingtcp { print; }
' "$NAT_CONF" > "$NAT_CONF.new"

mv "$NAT_CONF.new" "$NAT_CONF"
rm "$TEMP_NAT_BLOCK"
echo "[SUCCESS] NAT port forwarding rules applied."

# 4. Update Mac Hosts File
echo ""
echo "--- 3. Updating Mac Hosts File (${HOSTS_FILE}) ---"
create_backup "$HOSTS_FILE"

# Remove any existing entries for the hostname before appending
echo "[INFO] Cleaning up old host file entries for ${VM_HOSTNAME}..."
sed -i '' "/${VM_HOSTNAME}/d" "$HOSTS_FILE"

# Use the Mac's localhost IP (127.0.0.1) since traffic will hit the Mac's port before forwarding
echo "[INFO] Appending new hosts entry..."
echo "# VMware K3s VM Entry - ${VM_HOSTNAME}" >> "$HOSTS_FILE"
echo "127.0.0.1       ${VM_HOSTNAME}" >> "$HOSTS_FILE"
echo "[SUCCESS] Hosts file updated to point ${VM_HOSTNAME} to localhost."

# 5. Restart VMware Networking
echo ""
echo "--- 4. Restarting VMware Networking Service ---"
# Check if Fusion application path exists before attempting to restart the service
VMNET_CLI="/Applications/VMware Fusion.app/Contents/Library/vmnet-cli"

if [ -f "$VMNET_CLI" ]; then
    echo "[INFO] Stopping network services..."
    "$VMNET_CLI" --stop

    echo "[INFO] Starting network services to load new config..."
    "$VMNET_CLI" --start

    echo "[SUCCESS] VMware network services restarted."
else
    echo "[WARN] Could not find vmnet-cli. Manual restart required."
    echo "       Please fully restart VMware Fusion to load configuration changes."
fi

# 6. Final Instructions
echo ""
echo "--------------------------------------------------------"
echo "✅ Configuration COMPLETE."
echo ""
echo "MODIFIED FILES (Backup created for each in the same directory):"
echo "- DHCP Lease: ${DHCPD_CONF}"
echo "- Port Forwards: ${NAT_CONF}"
echo "- Hostname Resolution: ${HOSTS_FILE}"
echo ""
echo "NEXT STEPS:"
echo "1. Restart VMware Fusion if it was running."
echo "2. Start your Ubuntu VM."
echo "3. (Optional) Flush your Mac's DNS cache to ensure the hosts file update is recognized:"
echo "   dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
echo "--------------------------------------------------------"
echo ""
