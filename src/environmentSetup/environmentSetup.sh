#!/usr/bin/env bash
# environmentSetup.sh -- Mifos Gazelle environment setup script

source "$RUN_DIR/src/environmentSetup/helpers.sh" || { echo "FATAL: Could not source helpers.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/environmentSetup/k8s.sh" || { echo "FATAL: Could not source k8s.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/environmentSetup/mac_setup.sh" || { echo "FATAL: Could not source mac_setup.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }

#------------------------------------------------------------------------------
# Function: install_os_prerequisites   
# Description: Installs required operating system packages if they are not already installed.
#------------------------------------------------------------------------------
install_os_prerequisites() {
    log_step "Check & install operating system packages"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        ensure_homebrew
        if ! command -v jq &>/dev/null; then
            log_with_verbose_check "$debug" debug "jq is not installed. Installing via brew..."
            run_brew install jq >/dev/null 2>&1
        else
            log_with_verbose_check "$debug" debug "jq is already installed\n"
        fi
        log_ok
        return 0
    fi
    if ! command -v docker &> /dev/null; then
        log_with_verbose_check "$debug" debug "Docker is not installed. Installing Docker..."
        apt update >> /dev/null 2>&1
        apt install -y apt-transport-https ca-certificates curl software-properties-common >> /dev/null 2>&1
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg >> /dev/null 2>&1
        echo "deb [signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >> /dev/null 2>&1
        apt update >> /dev/null 2>&1
        apt install -y docker-ce docker-ce-cli containerd.io >> /dev/null 2>&1
        usermod -aG docker "$k8s_user"
        log_ok
    else
        log_with_verbose_check "$debug" debug "Docker is already installed.\n"
    fi
    if ! command -v nc &> /dev/null; then
        log_with_verbose_check "$debug" debug "nc (netcat) is not installed. Installing..."
        apt-get update >> /dev/null 2>&1
        apt-get install -y netcat >> /dev/null 2>&1
        log_ok
    else
        log_with_verbose_check "$debug" debug "nc (netcat) is already installed.\n"
    fi
    if ! command -v jq &> /dev/null; then
        log_with_verbose_check "$debug" debug "jq is not installed. Installing ..."
        apt-get update >> /dev/null 2>&1
        apt-get -y install jq >> /dev/null 2>&1
        log_ok
    else
        log_with_verbose_check "$debug" debug "jq is already installed\n"
    fi
    log_ok
}

#------------------------------------------------------------------------------
# Function: ensure_python_venv
# Description: Creates a project-local Python virtualenv at $RUN_DIR/.venv and
#              installs the packages listed in src/utils/data-loading/requirements.txt.
#              Uses the venv for all data-loading scripts so no system or
#              Homebrew Python packages are modified.
#              Idempotent: skips creation/install if already up to date.
#------------------------------------------------------------------------------
ensure_python_venv() {
    local venv_dir="$RUN_DIR/.venv"
    local requirements="$RUN_DIR/src/utils/data-loading/requirements.txt"

    log_step "Python virtualenv for data-loading scripts"

    # Create the venv as the k8s_user so they can run scripts without sudo
    if [[ ! -x "$venv_dir/bin/python3" ]]; then
        run_as_user "python3 -m venv \"$venv_dir\"" >/dev/null
        if [[ $? -ne 0 ]]; then
            log_error "Failed to create Python venv at $venv_dir"
            exit 1
        fi
    fi

    # Install/upgrade requirements (pip will skip packages already at the right version)
    run_as_user "\"$venv_dir/bin/pip\" install --quiet --upgrade pip" >/dev/null
    run_as_user "\"$venv_dir/bin/pip\" install --quiet -r \"$requirements\"" >/dev/null
    if [[ $? -ne 0 ]]; then
        log_error "Failed to install Python requirements"
        exit 1
    fi

    log_ok
}

#------------------------------------------------------------------------------
# Function: add_hosts
# Description: Updates the local /etc/hosts file with entries for Mifos Gazelle services when using a local cluster.
#------------------------------------------------------------------------------
# Marker used to bracket all Gazelle-managed /etc/hosts entries.
# The remove_hosts function deletes everything between these two lines.
GAZELLE_HOSTS_BEGIN="# BEGIN mifos-gazelle"
GAZELLE_HOSTS_END="# END mifos-gazelle"

#------------------------------------------------------------------------------
# Function: remove_hosts
# Description: Removes the mifos-gazelle block from /etc/hosts.
#              Safe to call even if the block is not present.
#------------------------------------------------------------------------------
remove_hosts() {
    perl -i -ne '
        if (/^\Q'"$GAZELLE_HOSTS_BEGIN"'\E/) { $skip=1 }
        print unless $skip;
        if (/^\Q'"$GAZELLE_HOSTS_END"'\E/)   { $skip=0 }
    ' /etc/hosts
}

#------------------------------------------------------------------------------
# Function: add_hosts
# Description: Writes a clearly-marked block of Gazelle service hostnames into
#              /etc/hosts.  Any existing block is replaced so the function is
#              idempotent and handles IP changes (e.g. after a VM restart).
#              The block is self-contained — no other lines are touched.
#------------------------------------------------------------------------------
add_hosts() {
    if [[ "$environment" == "local" || "$environment" == "mac" ]]; then
        log_step "Updating /etc/hosts for Gazelle services"

        local DOMAIN="${GAZELLE_DOMAIN:-mifos.gazelle.test}"

        local VNEXTHOSTS=( mongohost.$DOMAIN mongo-express.$DOMAIN \
            vnextadmin.$DOMAIN elasticsearch.$DOMAIN kibana.$DOMAIN redpanda-console.$DOMAIN \
            mongoexpress.$DOMAIN fspiop.$DOMAIN bluebank.$DOMAIN greenbank.$DOMAIN )

        local PHEEHOSTS=( ops.$DOMAIN ops-bk.$DOMAIN \
            bulk-processor.$DOMAIN connector-bulk.$DOMAIN messagegateway.$DOMAIN \
            minio-console.$DOMAIN bill-pay.$DOMAIN channel.$DOMAIN \
            channel-gsma.$DOMAIN crm.$DOMAIN mockpayment.$DOMAIN \
            mojaloop.$DOMAIN identity-mapper.$DOMAIN vouchers.$DOMAIN \
            zeebeops.$DOMAIN zeebe-operate.$DOMAIN zeebe-gateway.$DOMAIN \
            notifications.$DOMAIN )

        local MIFOSXHOSTS=( mifos.$DOMAIN )
        local ALL_GAZELLE_HOSTS=( "${MIFOSXHOSTS[@]}" "${PHEEHOSTS[@]}" "${VNEXTHOSTS[@]}" )

        # Determine which IP to use.
        #
        # For both mac (Colima) and local (k3s on Linux): read the node's InternalIP
        # directly from kubectl — this is the ground truth for what klipper-lb binds the
        # nginx LoadBalancer service to.  127.0.0.1 does NOT work on mac because
        # klipper-lb uses iptables DNAT for ports 80/443, bypassing Lima's port-forwarding.
        # Asking kubectl is more reliable than inspecting VM interface names, which vary
        # across Lima/Colima versions and network backends.
        local NODE_IP
        # The node may have both IPv4 and IPv6 InternalIP addresses; the jsonpath
        # returns both space-separated.  Filter to the first IPv4 address only.
        NODE_IP=$(sudo -u "$k8s_user" kubectl get nodes \
            --kubeconfig "$kubeconfig_path" \
            -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
            2>/dev/null \
            | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
        if [[ "$environment" == "mac" ]]; then
            NODE_IP="${NODE_IP:-192.168.5.1}"   # fallback: common Colima socket_vmnet node IP
        else
            NODE_IP="${NODE_IP:-127.0.0.1}"
        fi

        # Remove any existing Gazelle block (idempotent; handles IP changes).
        remove_hosts

        # Also strip any legacy unmarked lines that contain gazelle hostnames
        # (written by older versions of this script before the marker approach).
        # We remove only the gazelle tokens from each line; if other hostnames
        # (e.g. localhost) are on the same line they are preserved.  Lines that
        # become just an IP address after stripping are removed entirely.
        export GAZELLE_DOMAIN_SUFFIX="$DOMAIN"
        perl -pi -e '
            if (/\Q$ENV{GAZELLE_DOMAIN_SUFFIX}\E/ && !/^#/) {
                s/\s+\S*\Q$ENV{GAZELLE_DOMAIN_SUFFIX}\E\S*//g;
                $_ = "" if /^\s*[\d.:a-fA-F]+\s*[\r\n]*$/;
            }
        ' /etc/hosts

        # Append a fresh, clearly-marked block.  Nothing else in /etc/hosts
        # is read or modified.  One hostname per line avoids the ~1024-char
        # per-line limit on macOS which silently drops entries beyond that point.
        {
            printf '\n%s\n' "$GAZELLE_HOSTS_BEGIN"
            for _host in "${ALL_GAZELLE_HOSTS[@]}"; do
                printf '%s %s\n' "$NODE_IP" "$_host"
            done
            printf '%s\n' "$GAZELLE_HOSTS_END"
        } >> /etc/hosts

    else
        log_step "Updating /etc/hosts for Gazelle services"
        log_skipped
        return 0
    fi
    log_ok
}
#------------------------------------------------------------------------------
# Function: delete_k8s_local_cluster   
# Description: Deletes the local Kubernetes cluster and removes related configurations.
#------------------------------------------------------------------------------
delete_k8s_local_cluster() {
    log_step "removing local kubernetes cluster"
    rm -f /usr/local/bin/helm >> /dev/null 2>&1
    /usr/local/bin/k3s-uninstall.sh >> /dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        log_ok
    else
        log_warn "k3s not installed"
    fi
    perl -i -ne 'print unless /START_GAZELLE/ .. /END_GAZELLE/' "$k8s_user_home/.bashrc"
    perl -i -ne 'print unless /START_GAZELLE/ .. /END_GAZELLE/' "$k8s_user_home/.bash_profile"
}

print_end_message() {
    echo -e "\n${GREEN}============================"
    echo -e "Environment setup successful"
    echo -e "============================${RESET}"
}

#------------------------------------------------------------------------------
# Function: print_end_message_delete   
# Description: Prints a message indicating successful cleanup of the environment.
#------------------------------------------------------------------------------
print_end_message_delete() {
    echo -e "\n===================================================="
    echo -e "cleanup successful "
    echo -e "Thank you for using Mifos Gazelle"
    echo -e "======================================================"
    echo -e "Copyright © 2023 The Mifos Initiative\n"
}

print_remote_cluster_start_message() {
    echo -e "\n${BLUE}================================"
    echo -e "Remote Cluster Setup and deployment "
    echo -e "================================${RESET}\n"
}

#------------------------------------------------------------------------------
# Function: configure_k8s_user_env   
# Description: Configures the shell environment for the Kubernetes user.
#------------------------------------------------------------------------------
configure_k8s_user_env() {
    local shell_rc shell_profile completion_cmd complete_cmd
    start_message="# GAZELLE_START start of config added by mifos-gazelle #"
    end_message="#GAZELLE_END end of config added by mifos-gazelle #"

    if [[ "$(uname -s)" == "Darwin" ]]; then
        shell_rc="$k8s_user_home/.zshrc"
        shell_profile="$k8s_user_home/.zprofile"
        completion_cmd="source <(kubectl completion zsh)"
        complete_cmd="compdef k=kubectl"
    else
        shell_rc="$k8s_user_home/.bashrc"
        shell_profile="$k8s_user_home/.bash_profile"
        completion_cmd="source <(kubectl completion bash)"
        complete_cmd="complete -F __start_kubectl k"
    fi

    grep "start of config added by mifos-gazelle" "$shell_rc" >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        log_step "Configure user shell for kubernetes"
        printf "%s\n" "$start_message" >> "$shell_rc"
        echo "$completion_cmd" >> "$shell_rc"
        echo "alias k=kubectl " >> "$shell_rc"
        echo "$complete_cmd" >> "$shell_rc"
        echo "alias ksetns=\"kubectl config set-context --current --namespace\" " >> "$shell_rc"
        echo "alias ksetuser=\"kubectl config set-context --current --user\" " >> "$shell_rc"
        echo "alias cdg=\"cd $k8s_user_home/mifos-gazelle\" " >> "$shell_rc"
        echo "export PATH=\$PATH:/usr/local/bin" >> "$shell_rc"
        echo "export KUBECONFIG=$kubeconfig_path" >> "$shell_rc"
        printf "%s\n" "$end_message" >> "$shell_rc"

        perl -pi -e 's/^.*KUBECONFIG.*\n?//g' "$shell_profile"
        if [[ "$(uname -s)" == "Darwin" ]]; then
            echo "export KUBECONFIG=$kubeconfig_path" >> "$shell_profile"
        else
            perl -pi -e 's/^.*bashrc.*\n?//g' "$shell_profile"
            echo "source ~/.bashrc" >> "$shell_profile"
            echo "export KUBECONFIG=$kubeconfig_path" >> "$shell_profile"
        fi

        chown "$k8s_user":"$k8s_user" "$shell_rc" "$shell_profile"
        log_ok
    else
        log_step "user's shell already configured for k8s"
        log_skipped
    fi
}



#------------------------------------------------------------------------------
# Function: is_cluster_accessible   
# Description: Checks if the Kubernetes cluster is accessible by verifying that at least one node is in the 'Ready' state.
# Returns:
#   0 - Cluster is accessible and has at least one Ready node
#   1 - Cluster is not accessible or has no Ready nodes
#------------------------------------------------------------------------------
is_cluster_accessible() {
    local k8s_user_cmd="kubectl get nodes --request-timeout=5s"
    local k8s_user_status
    
    # Cluster reachable check
    if ! su - "$k8s_user" -c "$k8s_user_cmd" > /dev/null 2>&1; then
        # The command failed (e.g., cluster unreachable, bad auth, or bad 'k8s_user' setup)
        return 1
    fi
    
    # Check for at least 1 node being ready
    local ready_nodes=$(su - "$k8s_user" -c "$k8s_user_cmd" | grep -c " Ready ")    
    if [[ "$ready_nodes" -eq 0 ]]; then
        # This means we could access the cluster, but no nodes are reported as Ready.
        log_with_verbose_check "$debug" info "Kubernetes cluster is reachable, but zero nodes are in the 'Ready' state."
        return 1
    fi
    return 0
}
#------------------------------------------------------------------------------
# Function: env_setup_remote_cluster   
# Description: Sets up a remote Kubernetes cluster.
# Parameters:
#   $1 - Mode of operation: "deploy", "cleanapps"
#------------------------------------------------------------------------------
env_setup_remote_cluster() {
    local mode="$1"
    if ! is_cluster_accessible; then
        log_error "Remote kubernetes cluster is NOT accessible. Please check your KUBECONFIG and network connectivity."
        exit 1
    else
        log_step "Remote kubernetes cluster is accessible"
        log_ok
        return 0
    fi
    # note that we might need to install NGINX here or interrogate remote cluster for existing ingress controller
    # For now we assume remote cluster is pre-configured with an ingress controller
} 

#------------------------------------------------------------------------------
# Function: env_setup_local_cluster   
# Description: Sets up a local Kubernetes cluster using k3s.
# Parameters:
#   $1 - Mode of operation: "deploy", "cleanapps", or "cleanall"
#------------------------------------------------------------------------------
env_setup_local_cluster() {
    local mode="$1"

    if [[ "$mode" == "deploy" ]]; then
        check_resources_ok
        ensure_python_venv
        add_hosts

        if ! is_local_cluster_installed; then
            install_k3s
            $UTILS_DIR/install-k9s.sh > /dev/null 2>&1
        fi
        check_and_load_helm_repos
        install_nginx_local_cluster
        log_section "local kubernetes v${k8s_version} configured for ${k8s_user}"
        print_end_message
    elif [[ "$mode" == "cleanapps" ]]; then
        if ! is_local_cluster_installed; then
            log_error "Local kubernetes cluster is NOT installed"
            exit 1
        fi
        if ! is_cluster_accessible; then
            log_error "Local kubernetes cluster is NOT accessible"
            exit 1
        fi
    elif [[ "$mode" == "cleanall" ]]; then
        if ! is_local_cluster_installed; then
            log_warn "Local kubernetes cluster is NOT installed — nothing to delete."
            print_end_message_delete
            exit 0
        fi
        delete_k8s_local_cluster
        remove_hosts
        print_end_message_delete
    else
        show_usage
        exit 1
    fi
}   


env_setup_main() {
    local mode="$1"

    check_sudo
    check_arch_ok
    verify_user
    check_os_ok  
    install_os_prerequisites
    install_k8s_tools
    configure_k8s_user_env

    if [[ "$environment" == "local" ]]; then
        env_setup_local_cluster "$mode"
    elif [[ "$environment" == "remote" ]]; then
        print_remote_cluster_start_message
        env_setup_remote_cluster "$mode"
    elif [[ "$environment" == "mac" ]]; then
        env_setup_mac_cluster "$mode"
    else
        printf "** Error: Invalid environment type specified: %s. Must be 'local', 'remote', or 'mac'. **\n" "$environment"
        exit 1
    fi
} 

