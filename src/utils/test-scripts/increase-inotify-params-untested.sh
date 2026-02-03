#!/bin/bash

## Note this script is untested and should be run with caution. It modifies system parameters.
# This script increases the inotify limits for Kubernetes/container workloads.  
# it is captured here for subsequent testing and incorporation into the main Gazelle dpeloyment script.
# It is recommended to run this script on a test system before deploying it in production.
# This script is intended to be run on a Linux system with root privileges.

# Define the new inotify limits
WATCHES_LIMIT=1048576
INSTANCES_LIMIT=1024

# Define the configuration file
SYSCTL_FILE="/etc/sysctl.d/99-inotify.conf"

# Check if the script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

echo "Increasing fs.inotify.max_user_watches to ${WATCHES_LIMIT}"
echo "Increasing fs.inotify.max_user_instances to ${INSTANCES_LIMIT}"

# Apply the changes temporarily for the current session
sysctl -w fs.inotify.max_user_watches=${WATCHES_LIMIT}
if [ $? -ne 0 ]; then
    echo "Error applying fs.inotify.max_user_watches temporarily. Exiting."
    exit 1
fi

sysctl -w fs.inotify.max_user_instances=${INSTANCES_LIMIT}
if [ $? -ne 0 ]; then
    echo "Error applying fs.inotify.max_user_instances temporarily. Exiting."
    exit 1
fi

echo "Temporary limits applied."

# Make the changes persistent by adding to a sysctl configuration file
echo "Making changes persistent in ${SYSCTL_FILE}"

# Create or overwrite the configuration file with the new limits
cat <<EOF > ${SYSCTL_FILE}
# Increased inotify limits for Kubernetes/container workloads
fs.inotify.max_user_watches = ${WATCHES_LIMIT}
fs.inotify.max_user_instances = ${INSTANCES_LIMIT}
EOF

if [ $? -ne 0 ]; then
    echo "Error writing to ${SYSCTL_FILE}. Exiting."
    exit 1
fi

echo "Configuration saved to ${SYSCTL_FILE}."

# Load the sysctl configuration from the file
echo "Applying persistent configuration..."
sysctl --system
if [ $? -ne 0 ]; then
    echo "Error applying persistent configuration with 'sysctl --system'. Please check the file syntax."
    exit 1
fi

echo "Persistent configuration applied."

# Verify the new limits
echo "Verifying current limits:"
cat /proc/sys/fs/inotify/max_user_watches
cat /proc/sys/fs/inotify/max_user_instances

echo "Script finished. Please verify kubectl logs -f works now."