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
    # Install Python venv + pip -- ensurepip (needed by `python3 -m venv`) ships in the versioned python3.X-venv pkg, not base python3; without it setup aborts before k3s. Metapackages + derived versioned pkg cover both Ubuntu 22.04 and 24.04.
    if ! python3 -c "import ensurepip" >/dev/null 2>&1 || ! command -v pip3 &> /dev/null; then
        log_with_verbose_check "$debug" debug "Python venv/pip support is missing. Installing..."
        local py_ver
        py_ver="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)"
        apt-get update >> /dev/null 2>&1
        apt-get install -y python3-venv python3-pip >> /dev/null 2>&1
        [[ -n "$py_ver" ]] && apt-get install -y "python${py_ver}-venv" >> /dev/null 2>&1
        log_ok
    else
        log_with_verbose_check "$debug" debug "Python venv/pip support already present.\n"
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

    # Create the venv as the k8s_user so they can run scripts without sudo.
    # Uses sudo -u because this function runs from setup-env.sh (root context).
    if [[ ! -x "$venv_dir/bin/python3" ]]; then
        sudo -u "$k8s_user" python3 -m venv "$venv_dir" >/dev/null
        if [[ $? -ne 0 ]]; then
            log_error "Failed to create Python venv at $venv_dir"
            exit 1
        fi
    fi

    # Fail fast if the venv has no pip (missing python3.X-venv/ensurepip) instead of a cryptic "pip: command not found" further down.
    if [[ ! -x "$venv_dir/bin/pip" ]]; then
        log_error "Python venv at $venv_dir has no pip -- the python3-venv / ensurepip bootstrap is missing."
        log_error "Install it and re-run setup-env.sh: sudo apt-get install -y python3-venv python3-pip python3.X-venv (X matching 'python3 --version')."
        exit 1
    fi

    # Install/upgrade requirements (pip will skip packages already at the right version)
    sudo -u "$k8s_user" "$venv_dir/bin/pip" install --quiet --upgrade pip >/dev/null
    sudo -u "$k8s_user" "$venv_dir/bin/pip" install --quiet -r "$requirements" >/dev/null
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
        local OPENSPPHOSTS=( openspp.$DOMAIN )
        local ALL_GAZELLE_HOSTS=( "${MIFOSXHOSTS[@]}" "${PHEEHOSTS[@]}" "${VNEXTHOSTS[@]}" "${OPENSPPHOSTS[@]}" )
        local OPENG2PHOSTS=( openg2p.$DOMAIN social-registry.$DOMAIN \
            pbms.$DOMAIN spar.$DOMAIN g2p-bridge.$DOMAIN \
            keycloak.$DOMAIN minio-og2p.$DOMAIN )

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
# Function: remove_shell_config
# Description: Removes the Gazelle-managed block from the user's shell rc and
#              profile files.  Handles both macOS (zsh) and Linux (bash).
#              Safe to call even if the block is not present.
#------------------------------------------------------------------------------
remove_shell_config() {
    local shell_rc shell_profile
    if [[ "$(uname -s)" == "Darwin" ]]; then
        shell_rc="$k8s_user_home/.zshrc"
        shell_profile="$k8s_user_home/.zprofile"
    else
        shell_rc="$k8s_user_home/.bashrc"
        shell_profile="$k8s_user_home/.bash_profile"
    fi

    log_step "Shell config aliases block (${shell_rc##*/})"
    if [[ -f "$shell_rc" ]]; then
        perl -i -ne 'print unless /GAZELLE_START/ .. /GAZELLE_END/' "$shell_rc"
        log_with_verbose_check "$debug" "$DEBUG" "Removed GAZELLE_START..GAZELLE_END block from $shell_rc"
        log_ok
    else
        log_skipped
    fi

    log_step "Shell config KUBECONFIG export (${shell_profile##*/})"
    if [[ -f "$shell_profile" ]]; then
        perl -i -ne 'print unless /^export KUBECONFIG=/' "$shell_profile"
        log_with_verbose_check "$debug" "$DEBUG" "Removed export KUBECONFIG= line from $shell_profile"
        log_ok
    else
        log_skipped
    fi
}

#------------------------------------------------------------------------------
# Function: delete_k8s_local_cluster
# Description: Deletes the local Kubernetes cluster and removes related configurations.
#------------------------------------------------------------------------------
delete_k8s_local_cluster() {
    local _out _rc

    log_step "k3s cluster (k3s-uninstall.sh)"
    if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
        _out=$(/usr/local/bin/k3s-uninstall.sh 2>&1)
        _rc=$?
        if [[ $_rc -eq 0 ]]; then
            log_ok
        else
            log_warn "k3s-uninstall.sh returned $_rc (may already be removed)"
        fi
        log_with_verbose_check "$debug" "$DEBUG" "$_out"
    else
        log_skipped
    fi

    log_step "/usr/local/bin/helm"
    if [[ -f /usr/local/bin/helm ]]; then
        rm -f /usr/local/bin/helm
        log_ok
    else
        log_skipped
    fi
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
        printf "\n%s\n" "$start_message" >> "$shell_rc"
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
# Description: Validates connectivity to a pre-existing remote cluster.
#              Assumes the cluster already has an ingress controller installed.
#------------------------------------------------------------------------------
env_setup_remote_cluster() {
    if ! is_cluster_accessible; then
        log_error "Remote kubernetes cluster is NOT accessible. Please check your KUBECONFIG and network connectivity."
        exit 1
    fi
    log_step "Remote kubernetes cluster is accessible"
    log_ok
}

#------------------------------------------------------------------------------
# Function: env_setup_local_cluster
# Description: Installs and configures a local k3s Kubernetes cluster.
#              Teardown is handled by env_cleanall_main.
#------------------------------------------------------------------------------
env_setup_local_cluster() {
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
}


#------------------------------------------------------------------------------
# Function: show_planned_changes
# Description: Prints a manifest of every file, directory, and system resource
#              that setup-env.sh will touch, before any changes are made.
#              Output is OS- and environment-aware.
#------------------------------------------------------------------------------
show_planned_changes() {
    local os_type shell_rc shell_profile
    [[ "$(uname -s)" == "Darwin" ]] && os_type="macOS" || os_type="Linux"

    local user_home
    user_home=$(eval echo "~$k8s_user")
    if [[ "$os_type" == "macOS" ]]; then
        shell_rc="~/.zshrc"; shell_profile="~/.zprofile"
    else
        shell_rc="~/.bashrc"; shell_profile="~/.bash_profile"
    fi
    local kc="${kubeconfig_path:-$user_home/.kube/config}"
    kc="${kc/$user_home/\~}"

    local W=40   # left-column width

    printf "\n${CYAN}${BOLD}  ── Planned Changes  [%s / %s] %s${RESET}\n\n" \
        "$environment" "$os_type" "────────────────────────────────"

    printf "  ${BOLD}%-*s  %s${RESET}\n"  "$W" "Resource" "Change"
    printf "  %-*s  %s\n"  "$W" "$(printf '%0.s─' {1..40})" "$(printf '%0.s─' {1..30})"

    printf "  %-*s  %s\n"  "$W" "$shell_rc"    "kubectl aliases, completion, KUBECONFIG"
    printf "  %-*s  %s\n"  "$W" "$shell_profile" "KUBECONFIG export"

    if [[ "$environment" == "local" || "$environment" == "mac" ]]; then
        printf "  %-*s  %s\n"  "$W" "/etc/hosts" \
            "Add/replace Gazelle block (~30 hostnames)"
    fi

    if [[ "$os_type" == "macOS" ]]; then
        printf "  %-*s  %s\n"  "$W" "/etc/sudoers.d/colima"  "socket_vmnet sudoers snippet"
        printf "  %-*s  %s\n"  "$W" "Homebrew: colima docker helm k9s kubectx..." "Install if missing"
        if [[ "$environment" == "mac" ]]; then
            printf "  %-*s  %s\n"  "$W" "Colima Lima VM" \
                "Create/start  [k3s v${k8s_version:-1.30.0}]"
        fi
    else
        printf "  %-*s  %s\n"  "$W" "apt: docker-ce jq netcat..."  "Install if missing"
        if [[ "$environment" == "local" ]]; then
            printf "  %-*s  %s\n"  "$W" "/usr/local/bin  kubectl helm k9s kubens..." "Install if missing"
            printf "  %-*s  %s\n"  "$W" "/etc/sysctl.d/99-k3s.conf"  "inotify/fd limits for Java workloads"
            printf "  %-*s  %s\n"  "$W" "k3s v${k8s_version:-1.30}  (get.k3s.io)" \
                "Install; kubeconfig → $kc"
        fi
    fi

    if [[ "$environment" == "local" || "$environment" == "mac" ]]; then
        printf "  %-*s  %s\n"  "$W" ".venv/"  "Project Python virtualenv"
    fi

    printf "\n"
    if [[ "$os_type" == "macOS" ]]; then
        printf "  ${YELLOW}${BOLD}%-*s${RESET}  %s\n"  "$W" "WARNING" \
            "This is your desktop — changes are system-wide"
        printf "  %-*s  %s\n"  "$W" "" "Reversible: sudo ./setup-env.sh -m cleanall"
        printf "  %-*s  %s\n"  "$W" "" "Homebrew packages need manual brew uninstall"
    fi
    printf "\n"
}

#------------------------------------------------------------------------------
# Function: confirm_planned_changes
# Description: Prompts the user to confirm the planned changes listed by
#              show_planned_changes.  Reads from /dev/tty so the prompt works
#              even when stdin is a pipe.  Skipped when auto_yes=true (set via
#              the -y flag for CI/pipeline runs).
#------------------------------------------------------------------------------
confirm_planned_changes() {
    if [[ "${auto_yes:-false}" == "true" ]]; then
        printf "  Auto-accepted via -y flag.\n\n"
        return 0
    fi
    printf "\n  Proceed with these changes? [y/N] "
    local _ans
    read -r _ans </dev/tty
    if [[ "$_ans" != "y" && "$_ans" != "Y" ]]; then
        printf "  Aborted.\n"
        exit 0
    fi
    printf "\n"
}

env_setup_main() {
    check_arch_ok
    verify_user
    check_os_ok
    show_planned_changes
    confirm_planned_changes
    install_os_prerequisites
    install_k8s_tools
    configure_k8s_user_env

    if [[ "$environment" == "local" ]]; then
        env_setup_local_cluster
    elif [[ "$environment" == "remote" ]]; then
        print_remote_cluster_start_message
        env_setup_remote_cluster
    elif [[ "$environment" == "mac" ]]; then
        env_setup_mac_cluster
    else
        printf "** Error: Invalid environment type specified: %s. Must be 'local', 'remote', or 'mac'. **\n" "$environment"
        exit 1
    fi
}

#------------------------------------------------------------------------------
# Function: env_cleanall_main
# Description: Full environment teardown — called by setup-env.sh -m cleanall.
#              Removes k3s/Colima, /etc/hosts entries, and shell config added
#              by setup-env.sh. Does NOT delete application namespaces (use
#              ./run.sh -m cleanapps first on a live cluster).
#------------------------------------------------------------------------------
env_cleanall_main() {
    check_arch_ok
    verify_user

    log_section "Gazelle environment teardown [${environment}]"

    if [[ "$environment" == "local" ]]; then
        delete_k8s_local_cluster

        log_step "/etc/hosts Gazelle entries"
        remove_hosts
        log_ok

        remove_shell_config
        print_end_message_delete

    elif [[ "$environment" == "mac" ]]; then
        local _out _rc _colima

        # Uninstall ingress-nginx before wiping the VM so Helm state is cleaned first
        log_step "ingress-nginx Helm release"
        if is_cluster_accessible; then
            _out=$(helm uninstall ingress-nginx -n default 2>&1)
            _rc=$?
            if [[ $_rc -eq 0 ]]; then
                log_ok
            else
                log_skipped
            fi
            log_with_verbose_check "$debug" "$DEBUG" "$_out"
        else
            log_skipped
        fi

        log_step "/etc/hosts Gazelle entries"
        remove_hosts
        log_ok

        remove_shell_config

        if _colima=$(find_colima); then
            log_step "Colima VM: stop"
            _out=$(sudo -u "$k8s_user" "$_colima" stop 2>&1)
            _rc=$?
            if [[ $_rc -eq 0 ]]; then
                log_ok
            else
                log_warn "Colima VM not running or already stopped — safe to ignore if cleanall was run before"
            fi
            log_with_verbose_check "$debug" "$DEBUG" "$_out"

            log_step "Colima VM: delete"
            _out=$(sudo -u "$k8s_user" "$_colima" delete --yes 2>&1)
            _rc=$?
            if [[ $_rc -eq 0 ]]; then
                log_ok
            else
                log_warn "Colima VM not found or already deleted — safe to ignore if cleanall was run before"
            fi
            log_with_verbose_check "$debug" "$DEBUG" "$_out"

            log_step "~/.colima state directory"
            if [[ -d "$k8s_user_home/.colima" ]]; then
                rm -rf "$k8s_user_home/.colima"
                log_ok
            else
                log_skipped
            fi

            log_step "kubectl context: colima"
            _out=$(kubectl config delete-context colima 2>&1)
            _rc=$?
            [[ $_rc -eq 0 ]] && log_ok || log_skipped
            log_with_verbose_check "$debug" "$DEBUG" "$_out"

            log_step "docker context: colima"
            _out=$(sudo -u "$k8s_user" docker context rm colima 2>&1)
            _rc=$?
            [[ $_rc -eq 0 ]] && log_ok || log_skipped
            log_with_verbose_check "$debug" "$DEBUG" "$_out"
        else
            log_warn "Colima not found — skipping VM cleanup"
        fi
        print_end_message_delete

    elif [[ "$environment" == "remote" ]]; then
        log_step "/etc/hosts Gazelle entries"
        remove_hosts
        log_ok
        print_end_message_delete

    else
        log_error "Invalid environment '$environment'. Must be 'local', 'remote', or 'mac'."
        exit 1
    fi
}

