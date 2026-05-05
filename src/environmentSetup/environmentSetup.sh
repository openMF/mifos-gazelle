#!/usr/bin/env bash
# environmentSetup.sh -- Mifos Gazelle environment setup script

source "$RUN_DIR/src/environmentSetup/helpers.sh" || { echo "FATAL: Could not source helpers.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/environmentSetup/k8s.sh" || { echo "FATAL: Could not source k8s.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }

#------------------------------------------------------------------------------
# Function: install_os_prerequisites   
# Description: Installs required operating system packages if they are not already installed.
#------------------------------------------------------------------------------
function install_os_prerequisites {
    printf "\n\r==> Check & install operating system packages"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        _ensure_homebrew
        if ! command -v jq &>/dev/null; then
            logWithVerboseCheck "$debug" debug "jq is not installed. Installing via brew..."
            run_brew install jq >/dev/null 2>&1
        else
            logWithVerboseCheck "$debug" debug "jq is already installed\n"
        fi
        printf "       [ok]\n"
        return 0
    fi
    if ! command -v docker &> /dev/null; then
        logWithVerboseCheck "$debug" debug "Docker is not installed. Installing Docker..."
        apt update >> /dev/null 2>&1
        apt install -y apt-transport-https ca-certificates curl software-properties-common >> /dev/null 2>&1
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg >> /dev/null 2>&1
        echo "deb [signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >> /dev/null 2>&1
        apt update >> /dev/null 2>&1
        apt install -y docker-ce docker-ce-cli containerd.io >> /dev/null 2>&1
        usermod -aG docker "$k8s_user"
        printf "   ok \n"
    else
        logWithVerboseCheck "$debug" debug "Docker is already installed.\n"
    fi
    if ! command -v nc &> /dev/null; then
        logWithVerboseCheck "$debug" debug "nc (netcat) is not installed. Installing..."
        apt-get update >> /dev/null 2>&1
        apt-get install -y netcat >> /dev/null 2>&1
        printf "ok\n"
    else
        logWithVerboseCheck "$debug" debug "nc (netcat) is already installed.\n"
    fi
    if ! command -v jq &> /dev/null; then
        logWithVerboseCheck "$debug" debug "jq is not installed. Installing ..."
        apt-get update >> /dev/null 2>&1
        apt-get -y install jq >> /dev/null 2>&1
        printf "ok\n"
    else
        logWithVerboseCheck "$debug" debug "jq is already installed\n"
    fi
    printf "       [ok]\n"
}

#------------------------------------------------------------------------------
# Function: ensure_python_venv
# Description: Creates a project-local Python virtualenv at $RUN_DIR/.venv and
#              installs the packages listed in src/utils/data-loading/requirements.txt.
#              Uses the venv for all data-loading scripts so no system or
#              Homebrew Python packages are modified.
#              Idempotent: skips creation/install if already up to date.
#------------------------------------------------------------------------------
function ensure_python_venv {
    local venv_dir="$RUN_DIR/.venv"
    local requirements="$RUN_DIR/src/utils/data-loading/requirements.txt"

    printf "\r==> Python virtualenv for data-loading scripts  "

    # Create the venv as the k8s_user so they can run scripts without sudo
    if [[ ! -x "$venv_dir/bin/python3" ]]; then
        run_as_user "python3 -m venv \"$venv_dir\""
        if [[ $? -ne 0 ]]; then
            printf "\n** Error: failed to create Python venv at $venv_dir\n"
            exit 1
        fi
    fi

    # Install/upgrade requirements (pip will skip packages already at the right version)
    run_as_user "\"$venv_dir/bin/pip\" install --quiet --upgrade pip"
    run_as_user "\"$venv_dir/bin/pip\" install --quiet -r \"$requirements\""
    if [[ $? -ne 0 ]]; then
        printf "\n** Error: failed to install Python requirements\n"
        exit 1
    fi

    printf "        [ok]\n"
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
function remove_hosts {
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
function add_hosts {
    if [[ "$environment" == "local" || "$environment" == "mac" ]]; then
        printf "==> Mifos-gazelle: update local hosts file  "

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
        printf "==> Skipping /etc/hosts modification for remote cluster \n"
    fi
    printf "        [ok]\n"
}
#------------------------------------------------------------------------------
# Function: delete_k8s_local_cluster   
# Description: Deletes the local Kubernetes cluster and removes related configurations.
#------------------------------------------------------------------------------
function delete_k8s_local_cluster {
    printf "    removing local kubernetes cluster   "
    rm -f /usr/local/bin/helm >> /dev/null 2>&1
    /usr/local/bin/k3s-uninstall.sh >> /dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        printf "            [ok] \n"
    else
        echo -e "\n==> k3s not installed"
    fi
    perl -i -ne 'print unless /START_GAZELLE/ .. /END_GAZELLE/' "$k8s_user_home/.bashrc"
    perl -i -ne 'print unless /START_GAZELLE/ .. /END_GAZELLE/' "$k8s_user_home/.bash_profile"
}

function print_end_message {
    echo -e "\n${GREEN}============================"
    echo -e "Environment setup successful"
    echo -e "============================${RESET}"
}

#------------------------------------------------------------------------------
# Function: print_end_message_delete   
# Description: Prints a message indicating successful cleanup of the environment.
#------------------------------------------------------------------------------
function print_end_message_delete {
    echo -e "\n===================================================="
    echo -e "cleanup successful "
    echo -e "Thank you for using Mifos Gazelle"
    echo -e "======================================================"
    echo -e "Copyright © 2023 The Mifos Initiative\n"
}

function print_remote_cluster_start_message {
    echo -e "\n${BLUE}================================"
    echo -e "Remote Cluster Setup and deployment "
    echo -e "================================${RESET}\n"
}

#------------------------------------------------------------------------------
# Function: configure_k8s_user_env   
# Description: Configures the shell environment for the Kubernetes user.
#------------------------------------------------------------------------------
function configure_k8s_user_env {
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
        printf "==> Configure user shell for kubernetes "
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

        perl -p -i.bak -e 's/^.*KUBECONFIG.*\n?//g' "$shell_profile"
        if [[ "$(uname -s)" == "Darwin" ]]; then
            echo "export KUBECONFIG=$kubeconfig_path" >> "$shell_profile"
        else
            perl -p -i.bak -e 's/^.*bashrc.*\n?//g' "$shell_profile"
            echo "source ~/.bashrc" >> "$shell_profile"
            echo "export KUBECONFIG=$kubeconfig_path" >> "$shell_profile"
        fi

        chown "$k8s_user":"$k8s_user" "$shell_rc" "$shell_profile"
        printf "         [ok]\n"
    else
        printf "\r==> user's shell already configured for k8s       [skipping]\n"
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
        logWithVerboseCheck "$debug" info "Kubernetes cluster is reachable, but zero nodes are in the 'Ready' state."
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
function env_setup_remote_cluster {
    local mode="$1"
    if ! is_cluster_accessible; then
        printf "** Error: Remote kubernetes cluster is NOT accessible. Please check your KUBECONFIG and network connectivity. ** \n\n"
        exit 1
    else 
        printf "\r==> Remote kubernetes cluster is accessible       [ok]\n"
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
function env_setup_local_cluster {
    local mode="$1"

    if [[ "$mode" == "deploy" ]]; then
        check_resources_ok
        install_os_prerequisites
        ensure_python_venv
        add_hosts

        if ! is_local_cluster_installed; then
            install_k3s
            $UTILS_DIR/install-k9s.sh > /dev/null 2>&1
        fi
        check_and_load_helm_repos
        install_nginx_local_cluster
        printf "\r==> local kubernetes v%s configured  for %s \n" \
                  "$k8s_version" "$k8s_user"
        print_end_message
    elif [[ "$mode" == "cleanapps" ]]; then
        if ! is_local_cluster_installed; then
            printf "    ** Error:  Local kubernetes cluster is NOT installed   \n\n"
            exit 1
        fi
        if ! is_cluster_accessible; then
            printf "    ** Error: Local kubernetes cluster is NOT accessible   \n\n"
            exit 1
        fi
    elif [[ "$mode" == "cleanall" ]]; then
        #printf "\n==> Deleting local kubernetes cluster...  \n"
        if ! is_local_cluster_installed; then
            printf "    Local kubernetes cluster is NOT installed   \n"
            printf "    Nothing to delete. Exiting.\n\n"
            print_end_message_delete
            exit 0
        fi
        delete_k8s_local_cluster
        remove_hosts
        print_end_message_delete
    else
        showUsage
        exit 1
    fi
}   

#------------------------------------------------------------------------------
# Function: _configure_mac_vm_limits
# Description: Increases inotify and file-descriptor kernel limits inside the
#              Colima Lima VM.  Without this, Java/Spring-Boot pods that
#              open many fsnotify watchers (bulk-processor, zeebe-broker, etc.)
#              hit "too many open files" errors.  Settings are applied immediately
#              and written to /etc/sysctl.d/99-gazelle.conf so they survive Lima
#              VM restarts.  Idempotent: safe to call on every run.
#------------------------------------------------------------------------------
function _configure_mac_vm_limits {
    local colima
    if ! colima=$(_find_colima); then
        printf "    Warning: colima not found — skipping VM kernel limit tuning\n"
        return 0
    fi

    printf "    Configuring VM kernel limits (inotify / file descriptors)...\n"

    # Apply immediately (takes effect for all running and new processes).
    sudo -u "$k8s_user" "$colima" exec -- sudo sysctl -w fs.inotify.max_user_watches=1048576  >/dev/null 2>&1 || true
    sudo -u "$k8s_user" "$colima" exec -- sudo sysctl -w fs.inotify.max_user_instances=8192   >/dev/null 2>&1 || true
    sudo -u "$k8s_user" "$colima" exec -- sudo sysctl -w fs.file-max=2097152                  >/dev/null 2>&1 || true

    # Persist across Lima VM restarts (idempotent: only write if not already present).
    sudo -u "$k8s_user" "$colima" exec -- sudo sh -c \
        'grep -q max_user_watches /etc/sysctl.d/99-gazelle.conf 2>/dev/null || printf "fs.inotify.max_user_watches=1048576\nfs.inotify.max_user_instances=8192\nfs.file-max=2097152\n" > /etc/sysctl.d/99-gazelle.conf' \
        >/dev/null 2>&1 || true

    printf "    VM kernel limits configured            [ok]\n"
}

#------------------------------------------------------------------------------
# Function: _configure_mac_k3s_node_ip
# Description: Configures k3s inside the Colima Lima VM to bind to
#              the socket_vmnet (eth0) interface rather than the vznat interface.
#
#              Lima has two external interfaces:
#                eth0  (192.168.5.x) — socket_vmnet, directly routable from Mac
#                vznat (192.168.68.x) — VZ NAT for internet; overlaps with many
#                                       physical LAN subnets, causing routing
#                                       ambiguity on the Mac side.
#
#              Without this fix, k3s svclb binds to the vznat IP which the Mac
#              may route to a physical LAN device instead of the Lima VM.
#
#              Writes /etc/rancher/k3s/config.yaml inside the VM (persists on
#              the VM disk across restarts) and restarts k3s.  Idempotent.
#------------------------------------------------------------------------------
function _configure_mac_k3s_node_ip {
    local colima
    if ! colima=$(_find_colima); then
        printf "    Warning: colima not found — skipping k3s node-ip config\n"
        return 0
    fi

    # Detect eth0 IP inside the Lima VM (socket_vmnet, directly reachable from Mac)
    local eth0_ip
    eth0_ip=$(sudo -u "$k8s_user" "$colima" exec -- ip -4 addr show eth0 2>/dev/null \
        | awk '/inet /{print $2}' | cut -d'/' -f1)

    if [[ -z "$eth0_ip" ]]; then
        printf "    Warning: could not detect Lima VM eth0 IP — skipping k3s node-ip config\n"
        return 0
    fi

    printf "    Configuring k3s node-ip to %s (socket_vmnet eth0)...\n" "$eth0_ip"

    # Idempotent: skip if already configured with this IP
    local current_ip
    current_ip=$(sudo -u "$k8s_user" "$colima" exec -- \
        sudo sh -c 'grep -E "^node-ip:" /etc/rancher/k3s/config.yaml 2>/dev/null' \
        | awk -F'"' '{print $2}')
    if [[ "$current_ip" == "$eth0_ip" ]]; then
        printf "    k3s node-ip already set to %s   [ok]\n" "$eth0_ip"
        return 0
    fi

    # Write the config file inside the Lima VM
    sudo -u "$k8s_user" "$colima" exec -- sudo sh -c \
        "mkdir -p /etc/rancher/k3s && printf 'node-ip: \"%s\"\nnode-external-ip: \"%s\"\n' '$eth0_ip' '$eth0_ip' > /etc/rancher/k3s/config.yaml" \
        >/dev/null 2>&1

    # Restart k3s so it picks up the new node-ip config.
    # Try each init mechanism in turn; fall back to a full VM restart.
    printf "    Restarting k3s...\n"
    local restarted=false
    if sudo -u "$k8s_user" "$colima" exec -- sudo rc-service k3s restart >/dev/null 2>&1; then
        # OpenRC (Alpine Linux — Colima Lima VM)
        restarted=true
    elif sudo -u "$k8s_user" "$colima" exec -- sudo service k3s restart >/dev/null 2>&1; then
        restarted=true
    elif sudo -u "$k8s_user" "$colima" exec -- sudo dinitctl restart k3s >/dev/null 2>&1; then
        restarted=true
    else
        # No init service found — restart the whole VM (slowest but reliable)
        printf "    No k3s service manager found — restarting Colima VM...\n"
        sudo -u "$k8s_user" "$colima" stop >/dev/null 2>&1 || true
        sleep 5
        _start_colima
        restarted=true
    fi

    # Wait for the cluster to recover
    if [[ "$restarted" == true ]] && _wait_for_k8s 180; then
        printf "    k3s node-ip configured              [ok]\n"
    else
        printf "    Warning: k3s did not recover within 3 minutes after restart\n"
    fi
}

#------------------------------------------------------------------------------
# Function: _wait_for_k8s
# Description: Polls until the cluster is accessible or timeout is reached.
#              Also retries 'kubectl config use-context colima' on each
#              iteration because Colima writes its kubeconfig entry
#              asynchronously after starting — the context may not exist when
#              the loop begins.
# Parameters:
#   $1 - timeout in seconds (default 240)
#------------------------------------------------------------------------------
function _wait_for_k8s {
    local timeout="${1:-240}"
    local waited=0
    while ! is_cluster_accessible && [[ $waited -lt $timeout ]]; do
        su - "$k8s_user" -c "kubectl config use-context colima" >/dev/null 2>&1 || true
        sleep 5; (( waited += 5 ))
        printf "\r    Waiting for Colima Kubernetes (%ds/%ds)..." "$waited" "$timeout"
    done
    printf "\n"
    is_cluster_accessible
}

#------------------------------------------------------------------------------
# Function: _recover_mac_k8s
# Description: Attempts automatic recovery when the Colima VM is
#              running but the k3s cluster is not reachable.
#
#              Tier 1 (fast ~15s): removes any stale /etc/rancher/k3s/config.yaml
#              written by previous gazelle runs and restarts k3s in place.
#
#              Tier 2 (slower ~2min): if k3s is still unreachable, performs a
#              full colima stop + start to reset the VM cleanly.
#
# Returns: 0 if cluster becomes accessible, 1 if recovery failed.
#------------------------------------------------------------------------------
function _recover_mac_k8s {
    local colima
    if ! colima=$(_find_colima); then
        printf "    Warning: colima not found — cannot attempt auto-recovery\n"
        return 1
    fi

    # ---- Tier 1: clean stale config artifact + in-place k3s restart ----
    printf "    Auto-recovery tier 1: restarting k3s inside the VM...\n"
    sudo -u "$k8s_user" "$colima" exec -- sudo rm -f /etc/rancher/k3s/config.yaml >/dev/null 2>&1 || true
    sudo -u "$k8s_user" "$colima" exec -- sudo rc-service k3s restart >/dev/null 2>&1 || \
        sudo -u "$k8s_user" "$colima" exec -- sudo service k3s restart >/dev/null 2>&1 || true

    su - "$k8s_user" -c "kubectl config use-context colima" >/dev/null 2>&1 || true
    if _wait_for_k8s 60; then
        printf "    Auto-recovery tier 1 succeeded              [ok]\n"
        return 0
    fi

    # ---- Tier 2: full VM restart ----
    printf "    Auto-recovery tier 2: restarting Colima VM...\n"
    sudo -u "$k8s_user" "$colima" stop >/dev/null 2>&1 || true
    sleep 5
    _start_colima
    su - "$k8s_user" -c "kubectl config use-context colima" >/dev/null 2>&1 || true
    if _wait_for_k8s 240; then
        printf "    Auto-recovery tier 2 succeeded              [ok]\n"
        return 0
    fi

    printf "** Auto-recovery failed. Try:\n"
    printf "   1. Run: colima stop && colima start --kubernetes --kubernetes-version v1.30.0+k3s1 --runtime containerd --memory 16 --cpu 4\n"
    printf "   2. If the problem persists, run: colima delete && re-run ./run.sh\n"
    return 1
}

#------------------------------------------------------------------------------
# Function: install_mac_k8s
# Description: Ensures Colima (k3s) is running on macOS.
#              Colima is the supported provider — it uses k3s via Lima,
#              matching the Ubuntu environment and avoiding image pull issues.
#              Errors if another Kubernetes provider is found running.
#------------------------------------------------------------------------------
#------------------------------------------------------------------------------
# Function: _ensure_homebrew
# Description: Auto-installs Homebrew if not present. Safe to call as root
#              (uses sudo -u $k8s_user internally). Exits on failure.
#------------------------------------------------------------------------------
function _ensure_homebrew {
    if brew_available; then
        return 0
    fi
    printf "    Homebrew not found — installing (this may take a few minutes)...\n"
    sudo -u "$k8s_user" /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        </dev/null
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    if ! brew_available; then
        printf "** Error: Homebrew installation failed. Install manually from https://brew.sh **\n"
        exit 1
    fi
    printf "    Homebrew installed                       [ok]\n"
}

#------------------------------------------------------------------------------
# Function: _find_colima
# Description: Locates the colima binary at known macOS install paths.
#              colima is not on PATH when running via sudo, so we check
#              known Homebrew locations explicitly.
#------------------------------------------------------------------------------
function _find_colima {
    for candidate in \
        "/opt/homebrew/bin/colima" \
        "/usr/local/bin/colima"; do
        if [[ -x "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    if command -v colima &>/dev/null; then
        command -v colima; return 0
    fi
    return 1
}

#------------------------------------------------------------------------------
# Function: _start_colima
# Description: Starts Colima with k3s and containerd for standard Gazelle use.
#              k3s version matches the Ubuntu local environment.
#              containerd is used (not Docker) for consistency.
#------------------------------------------------------------------------------
function _start_colima {
    local colima
    if ! colima=$(_find_colima); then
        printf "** Error: colima not found. Install with: brew install colima\n"
        exit 1
    fi
    # Pass Homebrew PATH explicitly — sudo strips PATH so colima's internal
    # kubectl dependency check fails without it.
    sudo -u "$k8s_user" env PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" \
        "$colima" start \
        --kubernetes \
        --kubernetes-version "v1.30.0+k3s1" \
        --runtime docker \
        --memory 16 \
        --cpu 4 \
        --network-address
}

function install_mac_k8s {
    printf "\r==> Checking macOS Kubernetes provider\n"
    _ensure_homebrew

    # socket_vmnet sudoers: required for colima --network-address to get a routable VM IP.
    # colima sudoers emits the necessary /etc/sudoers.d snippet; idempotent on every run.
    local colima_bin
    if colima_bin=$(_find_colima); then
        sudo -u "$k8s_user" "$colima_bin" sudoers 2>/dev/null \
            | tee /etc/sudoers.d/colima >/dev/null 2>&1 || true
    fi

    # Ensure kubeconfig context is colima if available (may be stale from prior provider)
    su - "$k8s_user" -c "kubectl config use-context colima" >/dev/null 2>&1 || true

    # If cluster is accessible, verify it is Colima
    if is_cluster_accessible; then
        local current_context
        current_context=$(su - "$k8s_user" -c "kubectl config current-context" 2>/dev/null)
        if [[ "$current_context" != "colima" ]]; then
            printf "** Error: A Kubernetes cluster is already running but it is not Colima.\n"
            printf "   Current context: %s\n" "$current_context"
            printf "   mifos-gazelle requires Colima on macOS.\n"
            printf "   Please stop the other provider and re-run.\n"
            exit 1
        fi
        printf "    Colima Kubernetes is ready                 [ok]\n"
        return 0
    fi

    # VM may already be running in a broken state (e.g. kubelet crashed due to a
    # stale config artifact from a previous run).  Try auto-recovery before
    # attempting a full start, so we don't waste time shutting down a live VM.
    local colima
    if colima=$(_find_colima); then
        local vm_state
        vm_state=$(sudo -u "$k8s_user" "$colima" list --json 2>/dev/null \
            | python3 -c "import sys,json; items=json.load(sys.stdin); print(items[0].get('status','') if items else '')" 2>/dev/null || true)
        if [[ "$vm_state" == "Running" ]]; then
            printf "    VM is running but cluster is unreachable — attempting auto-recovery...\n"
            if _recover_mac_k8s; then
                printf "    Colima Kubernetes is ready                 [ok]\n"
                return 0
            fi
            # Recovery failed — fall through to a clean start below
        fi
    fi

    # Colima installed but not running (or recovery failed) — start it
    if colima=$(_find_colima); then
        printf "    Colima found, starting...\n"
        _start_colima
        # Ensure kubeconfig points at colima (may be stale from a previous provider)
        su - "$k8s_user" -c "kubectl config use-context colima" >/dev/null 2>&1 || true
        if _wait_for_k8s 240; then
            printf "    Colima Kubernetes is ready                 [ok]\n"
            return 0
        fi
        printf "** Error: Colima did not become ready.\n"
        printf "   Run: colima list    and check for errors.\n"
        exit 1
    fi

    # Not installed — install Colima + Docker tooling via Homebrew then start
    printf "    Colima not found. Installing via Homebrew (this may take a few minutes)...\n"
    if ! sudo -u "$k8s_user" brew install colima docker docker-compose; then
        printf "** Error: Colima installation failed.\n"
        exit 1
    fi
    printf "    Starting Colima with Kubernetes (this may take a few minutes)...\n"
    _start_colima
    if ! _wait_for_k8s 300; then
        printf "** Error: Colima did not become ready.\n"
        exit 1
    fi
    printf "    Colima Kubernetes is ready                 [ok]\n"
}

#------------------------------------------------------------------------------
# Function: env_setup_mac_cluster
# Description: Sets up Gazelle on a macOS host using Colima (k3s) as the
#              Kubernetes provider.
# Parameters:
#   $1 - Mode of operation: "deploy", "cleanapps", or "cleanall"
#------------------------------------------------------------------------------
function env_setup_mac_cluster {
    local mode="$1"
    if [[ "$mode" == "deploy" ]]; then
        check_resources_ok
        install_mac_k8s
        _configure_mac_vm_limits
        # NOTE: _configure_mac_k3s_node_ip is intentionally NOT called here.
        # The default Colima k3s setup works correctly without explicit node-ip binding.
        # The function exists and is updated for potential future use if needed.
        ensure_python_venv
        add_hosts
        check_and_load_helm_repos
        install_nginx_local_cluster
        printf "\r==> macOS kubernetes cluster configured for %s\n" "$k8s_user"
        print_end_message
    elif [[ "$mode" == "cleanapps" || "$mode" == "cleanall" ]]; then
        if is_cluster_accessible; then
            # Cluster is up — delete namespaces and helm releases cleanly
            if [[ "$mode" == "cleanapps" ]]; then
                : # app deletion handled by deleteApps called from commandline.sh
            else
                log_step "Removing ingress-nginx"
                run_as_user "helm uninstall ingress-nginx -n default" >/dev/null 2>&1 || true
                log_ok
            fi
        else
            if [[ "$mode" == "cleanapps" ]]; then
                printf "** Error: Kubernetes cluster is NOT accessible\n\n"
                exit 1
            else
                printf "    Warning: Kubernetes cluster is not accessible — skipping namespace cleanup\n"
            fi
        fi
        remove_hosts
        if [[ "$mode" == "cleanall" ]]; then
            # Delete the Colima VM entirely — full wipe of k3s state and images.
            # colima delete stops the VM first if running, then removes the disk.
            local colima
            if colima=$(_find_colima); then
                log_step "Deleting Colima VM (full cleanall)"
                # --yes skips the interactive confirmation prompt.
                # Stop first (ignoring errors if already stopped) so containerd
                # shuts down cleanly before delete removes the disk; this avoids
                # the ttrpc/JSON errors that occur when delete tries to stop a
                # partially-running VM itself.
                sudo -u "$k8s_user" "$colima" stop 2>/dev/null || true
                sudo -u "$k8s_user" "$colima" delete --yes 2>/dev/null || true
                # colima delete leaves behind ~/.colima (named disks, Lima config, SSH
                # config) which can hold 20-30 GB of disk images. Remove the entire
                # directory for a true cleanall — Colima recreates it on next start.
                rm -rf "$k8s_user_home/.colima" 2>/dev/null || true
                log_ok
                # Remove stale kubeconfig and Docker contexts left by the deleted VM.
                su - "$k8s_user" -c "kubectl config delete-context colima" >/dev/null 2>&1 || true
                sudo -u "$k8s_user" docker context rm colima >/dev/null 2>&1 || true
            fi
        fi
    else
        showUsage
        exit 1
    fi
}

function env_setup_main() {
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

# Getting rid of the fsnotify too many open files errors for local k3s install do this 
# # 1. Automate Kernel Parameter Configuration
# echo "Configuring Linux kernel parameters for K3s..."

# sudo tee /etc/sysctl.d/99-k3s.conf <<EOF
# fs.inotify.max_user_watches = 524288
# fs.inotify.max_user_instances = 1024
# fs.file-max = 2097152
# EOF

# # Load the new settings immediately
# sudo sysctl --system

# # 2. Install K3s (This command will install and start the service)
# echo "Installing K3s..."
# curl -sfL https://get.k3s.io | sh -

# # 3. Verify K3s status
# echo "K3s installation complete. Checking status..."
# sudo systemctl status k3s --no-pager