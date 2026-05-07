#!/usr/bin/env bash
# helper functions for OS and kubernetes environment setup

#------------------------------------------------------------------------------
# run_brew <args>
# Locates the Homebrew binary at its known macOS install paths (sudo strips
# PATH so 'command -v brew' fails) and runs it as the invoking non-root user.
#------------------------------------------------------------------------------
run_brew() {
    local brew_bin=""
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [[ -x "$candidate" ]]; then brew_bin="$candidate"; break; fi
    done
    if [[ -z "$brew_bin" ]]; then
        printf "** Error: Homebrew not found at /opt/homebrew/bin or /usr/local/bin.\n"
        printf "   Install from https://brew.sh then re-run.\n"
        exit 1
    fi
    sudo -u "${SUDO_USER:-$k8s_user}" "$brew_bin" "$@"
}

brew_available() {
    [[ -x "/opt/homebrew/bin/brew" ]] || [[ -x "/usr/local/bin/brew" ]]
}

check_arch_ok() {
    local arch=$(uname -m)
    if [[ "$arch" != "x86_64" && "$arch" != "arm64" && "$arch" != "aarch64" ]]; then
        printf " **** Error Unknown CPU architecture : mifos-gazelle only works properly with x86_64, arm64, or aarch64 architectures today  *****\n"
        exit 1 
    fi
}

check_resources_ok() {
    local total_ram free_space
    if [[ "$(uname -s)" == "Darwin" ]]; then
        total_ram=$(( $(sysctl -n hw.memsize) / 1073741824 ))
        free_space=$(df -k ~ | awk 'NR==2 {printf "%d", $4/1048576}')
    else
        total_ram=$(free -g | awk '/^Mem:/{print $2}')
        free_space=$(df -BG ~ | awk '{print $4}' | tail -n 1 | sed 's/G//')
    fi
    if [[ "$total_ram" -lt "$MIN_RAM" ]]; then
        printf " ** Error: mifos-gazelle currently requires $MIN_RAM GBs to run properly \n"
        printf "    Please increase RAM available before trying to run mifos-gazelle \n"
        exit 1
    fi
    if [[ "$free_space" -lt "$MIN_FREE_SPACE" ]] ; then
        printf " ** Warning: mifos-gazelle currently requires %sGBs free storage in %s home directory  \n" "$MIN_FREE_SPACE" "$k8s_user"
        printf "    but only found %sGBs free storage \n" "$free_space"
        printf "    mifos-gazelle installation will continue, but beware it might fail later due to insufficient storage \n"
    fi
}

set_linux_os_distro() {
    LINUX_VERSION="Unknown"
    if [ -x "/usr/bin/lsb_release" ]; then
        LINUX_OS=`lsb_release --d | perl -ne 'print if s/^.*Ubuntu.*(\d+).(\d+).*$/Ubuntu/' `
        LINUX_VERSION=`/usr/bin/lsb_release --d | perl -ne 'print $& if m/(\d+)/' `
    else
        LINUX_OS="Untested"
    fi
    #printf "\r     Linux OS is [%s] " "$LINUX_OS"
}

check_os_ok() {
    printf "\r==> checking operating system is tested with mifos-gazelle\n"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        local mac_version
        mac_version=$(sw_vers -productVersion 2>/dev/null)
        printf "    macOS %s detected\n" "$mac_version"
        log_step "Operating system check"
        log_ok
        return 0
    fi
    set_linux_os_distro
    # Only Linux OS supported at this time
    if [[ ! $LINUX_OS == "Ubuntu" ]]; then
        printf "** Error, Mifos Gazelle is only tested with Ubuntu OS at this time   **\n"
        exit 1
    fi
    echo "    Linux OS is $LINUX_OS and version $LINUX_VERSION"
    echo "    Tested Ubuntu versions are: ${ubuntu_ok_versions_list[*]}"
    if [[ ! " ${ubuntu_ok_versions_list[*]} " =~ " ${LINUX_VERSION} " ]]; then
        printf "** Error, Mifos Gazelle is only tested with Ubuntu this time   **\n"
        exit 1
    fi
    log_step "Operating system check"
    log_ok
}

verify_user() {
    if [ -z ${k8s_user+x} ]; then
        printf "** Error: The operating system user has not been specified with the -u flag \n"
        printf "          the user specified with the -u flag must exist and not be the root user \n"
        printf "** \n"
        exit 1
    fi
    if [[ `id -u $k8s_user >/dev/null 2>&1; echo $?` == 0 ]]; then
        if [[ `id -u $k8s_user` == 0 ]]; then
            printf "** Error: The user specified by -u should be a non-root user ** \n"
            exit 1
        fi
    else
        printf "** Error: The user [ %s ] does not exist in the operating system \n" "$k8s_user"
        printf "            please try again and specify an existing user \n"
        printf "** \n"
        exit 1
    fi
    k8s_user_home=`eval echo "~$k8s_user"`
}

# check which kubernetes related tools are installed 
check_tools() {
    # Set the default tools to check (helm and kubectl)
    local tools=("helm" "kubectl")

    # If arguments are provided, use them instead of the default list
    if [ "$#" -gt 0 ]; then
        tools=("$@")
    fi

    # Loop through the list of tools and check each one
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            echo "Error: '$tool' is not installed. Check failed." >&2
            return 1 # Return 1 (failure) without exiting the script
        fi
    done

    return 0 # Return 0 (success) if all tools were found
}

is_local_cluster_installed()  {
    if [[ -f /usr/local/bin/k3s ]]; then
        #echo "local Kubernetes Cluster (k3s) is installed."
        return 0 # Success
    else
        return 1 # Failure
    fi
}


configure_k3s_kernel_params() {
    echo "Checking current kernel parameters for K3s..."
    
    # Define target values
    local target_max_watches=524288
    local target_max_instances=1024
    local target_file_max=2097152
    
    # Get current values
    local current_watches=$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)
    local current_instances=$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)
    local current_file_max=$(sysctl -n fs.file-max 2>/dev/null || echo 0)
    
    # Check if values already match targets
    local needs_update=false
    
    if [ "$current_watches" -ne "$target_max_watches" ]; then
        echo "  fs.inotify.max_user_watches: $current_watches -> $target_max_watches"
        needs_update=true
    else
        echo "  fs.inotify.max_user_watches: $current_watches (already set)"
    fi
    
    if [ "$current_instances" -ne "$target_max_instances" ]; then
        echo "  fs.inotify.max_user_instances: $current_instances -> $target_max_instances"
        needs_update=true
    else
        echo "  fs.inotify.max_user_instances: $current_instances (already set)"
    fi
    
    if [ "$current_file_max" -ne "$target_file_max" ]; then
        echo "  fs.file-max: $current_file_max -> $target_file_max"
        needs_update=true
    else
        echo "  fs.file-max: $current_file_max (already set)"
    fi
    
    # Apply settings if needed
    if [ "$needs_update" = true ]; then
        echo ""
        echo "Applying kernel parameter configuration..."
        
        sudo tee /etc/sysctl.d/99-k3s.conf <<EOF
fs.inotify.max_user_watches = $target_max_watches
fs.inotify.max_user_instances = $target_max_instances
fs.file-max = $target_file_max
EOF
        
        # Load the new settings immediately
        sudo sysctl --system
        
        echo ""
        echo "✓ Kernel parameters configured successfully!"
    else
        echo ""
        echo "✓ All kernel parameters already set correctly. No changes needed."
    fi
}