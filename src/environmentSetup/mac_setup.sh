#!/usr/bin/env bash
# mac_setup.sh -- macOS/Colima-specific environment setup. Sourced by environmentSetup.sh.

#------------------------------------------------------------------------------
# Activates the colima kubeconfig context. Silently ignores failure — the
# context may not exist yet if Colima is still starting.
#------------------------------------------------------------------------------
use_colima_context() {
    su - "$k8s_user" -c "kubectl config use-context colima" >/dev/null 2>&1 || true
}

#------------------------------------------------------------------------------
# Function: configure_mac_vm_limits
# Description: Increases inotify and file-descriptor kernel limits inside the
#              Colima Lima VM.  Without this, Java/Spring-Boot pods that
#              open many fsnotify watchers (bulk-processor, zeebe-broker, etc.)
#              hit "too many open files" errors.  Settings are applied immediately
#              and written to /etc/sysctl.d/99-gazelle.conf so they survive Lima
#              VM restarts.  Idempotent: safe to call on every run.
#------------------------------------------------------------------------------
configure_mac_vm_limits() {
    local colima
    if ! colima=$(find_colima); then
        log_warn "colima not found — skipping VM kernel limit tuning"
        return 0
    fi

    log_step "Configuring VM kernel limits"

    # Apply immediately (takes effect for all running and new processes).
    sudo -u "$k8s_user" "$colima" exec -- sudo sysctl -w fs.inotify.max_user_watches=1048576  >/dev/null 2>&1 || true
    sudo -u "$k8s_user" "$colima" exec -- sudo sysctl -w fs.inotify.max_user_instances=8192   >/dev/null 2>&1 || true
    sudo -u "$k8s_user" "$colima" exec -- sudo sysctl -w fs.file-max=2097152                  >/dev/null 2>&1 || true

    # Persist across Lima VM restarts (idempotent: only write if not already present).
    sudo -u "$k8s_user" "$colima" exec -- sudo sh -c \
        'grep -q max_user_watches /etc/sysctl.d/99-gazelle.conf 2>/dev/null || printf "fs.inotify.max_user_watches=1048576\nfs.inotify.max_user_instances=8192\nfs.file-max=2097152\n" > /etc/sysctl.d/99-gazelle.conf' \
        >/dev/null 2>&1 || true

    log_ok
}

#------------------------------------------------------------------------------
# Function: configure_mac_k3s_node_ip
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
configure_mac_k3s_node_ip() {
    local colima
    if ! colima=$(find_colima); then
        log_warn "colima not found — skipping k3s node-ip config"
        return 0
    fi

    # Detect eth0 IP inside the Lima VM (socket_vmnet, directly reachable from Mac)
    local eth0_ip
    eth0_ip=$(sudo -u "$k8s_user" "$colima" exec -- ip -4 addr show eth0 2>/dev/null \
        | awk '/inet /{print $2}' | cut -d'/' -f1)

    if [[ -z "$eth0_ip" ]]; then
        log_warn "could not detect Lima VM eth0 IP — skipping k3s node-ip config"
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
        start_colima
        restarted=true
    fi

    # Wait for the cluster to recover
    if [[ "$restarted" == true ]] && wait_for_k8s 180; then
        printf "    k3s node-ip configured              [ok]\n"
    else
        log_warn "k3s did not recover within 3 minutes after restart"
    fi
}

#------------------------------------------------------------------------------
# Function: wait_for_k8s
# Description: Polls until the cluster is accessible or timeout is reached.
#              Also retries 'kubectl config use-context colima' on each
#              iteration because Colima writes its kubeconfig entry
#              asynchronously after starting — the context may not exist when
#              the loop begins.
# Parameters:
#   $1 - timeout in seconds (default 240)
#------------------------------------------------------------------------------
wait_for_k8s() {
    local timeout="${1:-240}"
    local waited=0
    while ! is_cluster_accessible && [[ $waited -lt $timeout ]]; do
        use_colima_context
        sleep 5; (( waited += 5 ))
        printf "\r    Waiting for Colima Kubernetes (%ds/%ds)..." "$waited" "$timeout"
    done
    printf "\n"
    is_cluster_accessible
}

#------------------------------------------------------------------------------
# Function: recover_mac_k8s
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
recover_mac_k8s() {
    local colima
    if ! colima=$(find_colima); then
        log_error "colima not found — cannot attempt auto-recovery"
        return 1
    fi

    # ---- Tier 1: clean stale config artifact + in-place k3s restart ----
    printf "    Auto-recovery tier 1: restarting k3s inside the VM...\n"
    sudo -u "$k8s_user" "$colima" exec -- sudo rm -f /etc/rancher/k3s/config.yaml >/dev/null 2>&1 || true
    sudo -u "$k8s_user" "$colima" exec -- sudo rc-service k3s restart >/dev/null 2>&1 || \
        sudo -u "$k8s_user" "$colima" exec -- sudo service k3s restart >/dev/null 2>&1 || true

    use_colima_context
    if wait_for_k8s 60; then
        log_step "Auto-recovery tier 1 succeeded"
        log_ok
        return 0
    fi

    # ---- Tier 2: full VM restart ----
    printf "    Auto-recovery tier 2: restarting Colima VM...\n"
    sudo -u "$k8s_user" "$colima" stop >/dev/null 2>&1 || true
    sleep 5
    start_colima
    use_colima_context
    if wait_for_k8s 240; then
        log_step "Auto-recovery tier 2 succeeded"
        log_ok
        return 0
    fi

    log_error "Auto-recovery failed. Try:"
    printf "   1. Run: colima stop && colima start --kubernetes --kubernetes-version v1.30.0+k3s1 --runtime containerd --memory 16 --cpu 4\n"
    printf "   2. If the problem persists, run: colima delete && re-run ./run.sh\n"
    return 1
}

#------------------------------------------------------------------------------
# Function: ensure_homebrew
# Description: Auto-installs Homebrew if not present. Safe to call as root
#              (uses sudo -u $k8s_user internally). Exits on failure.
#------------------------------------------------------------------------------
ensure_homebrew() {
    if brew_available; then
        return 0
    fi
    printf "    Homebrew not found — installing (this may take a few minutes)...\n"
    sudo -u "$k8s_user" /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        </dev/null
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    if ! brew_available; then
        log_error "Homebrew installation failed. Install manually from https://brew.sh"
        exit 1
    fi
    log_step "Homebrew installed"
    log_ok
}

#------------------------------------------------------------------------------
# Function: find_colima
# Description: Locates the colima binary at known macOS install paths.
#              colima is not on PATH when running via sudo, so we check
#              known Homebrew locations explicitly.
#------------------------------------------------------------------------------
find_colima() {
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
# Function: start_colima
# Description: Starts Colima with k3s and containerd for standard Gazelle use.
#              k3s version matches the Ubuntu local environment.
#              containerd is used (not Docker) for consistency.
#------------------------------------------------------------------------------
start_colima() {
    local colima
    if ! colima=$(find_colima); then
        log_error "colima not found. Install with: brew install colima"
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

#------------------------------------------------------------------------------
# Function: install_mac_k8s
# Description: Ensures Colima (k3s) is running on macOS.
#              Colima is the supported provider — it uses k3s via Lima,
#              matching the Ubuntu environment and avoiding image pull issues.
#              Errors if another Kubernetes provider is found running.
#------------------------------------------------------------------------------
install_mac_k8s() {
    log_section "Checking macOS Kubernetes provider"
    ensure_homebrew

    # socket_vmnet sudoers: required for colima --network-address to get a routable VM IP.
    # colima sudoers emits the necessary /etc/sudoers.d snippet; idempotent on every run.
    local colima_bin
    if colima_bin=$(find_colima); then
        sudo -u "$k8s_user" "$colima_bin" sudoers 2>/dev/null \
            | tee /etc/sudoers.d/colima >/dev/null 2>&1 || true
    fi

    # Ensure kubeconfig context is colima if available (may be stale from prior provider)
    use_colima_context

    # If cluster is accessible, verify it is Colima
    if is_cluster_accessible; then
        local current_context
        current_context=$(su - "$k8s_user" -c "kubectl config current-context" 2>/dev/null)
        if [[ "$current_context" != "colima" ]]; then
            log_error "A Kubernetes cluster is already running but it is not Colima."
            printf "   Current context: %s\n" "$current_context"
            printf "   mifos-gazelle requires Colima on macOS.\n"
            printf "   Please stop the other provider and re-run.\n"
            exit 1
        fi
        log_step "Colima Kubernetes is ready"
        log_ok
        return 0
    fi

    # VM may already be running in a broken state (e.g. kubelet crashed due to a
    # stale config artifact from a previous run).  Try auto-recovery before
    # attempting a full start, so we don't waste time shutting down a live VM.
    local colima
    if colima=$(find_colima); then
        local vm_state
        vm_state=$(sudo -u "$k8s_user" "$colima" list --json 2>/dev/null \
            | python3 -c "import sys,json; items=json.load(sys.stdin); print(items[0].get('status','') if items else '')" 2>/dev/null || true)
        if [[ "$vm_state" == "Running" ]]; then
            printf "    VM is running but cluster is unreachable — attempting auto-recovery...\n"
            if recover_mac_k8s; then
                log_step "Colima Kubernetes is ready"
        log_ok
                return 0
            fi
            # Recovery failed — fall through to a clean start below
        fi
    fi

    # Colima installed but not running (or recovery failed) — start it
    if colima=$(find_colima); then
        printf "    Colima found, starting...\n"
        start_colima
        # Ensure kubeconfig points at colima (may be stale from a previous provider)
        use_colima_context
        if wait_for_k8s 240; then
            log_step "Colima Kubernetes is ready"
        log_ok
            return 0
        fi
        log_error "Colima did not become ready."
        printf "   Run: colima list    and check for errors.\n"
        exit 1
    fi

    # Not installed — install Colima + Docker tooling via Homebrew then start
    printf "    Colima not found. Installing via Homebrew (this may take a few minutes)...\n"
    if ! sudo -u "$k8s_user" brew install colima docker docker-compose; then
        log_error "Colima installation failed."
        exit 1
    fi
    printf "    Starting Colima with Kubernetes (this may take a few minutes)...\n"
    start_colima
    if ! wait_for_k8s 300; then
        log_error "Colima did not become ready."
        exit 1
    fi
    log_step "Colima Kubernetes is ready"
        log_ok
}

#------------------------------------------------------------------------------
# Function: env_setup_mac_cluster
# Description: Sets up Gazelle on a macOS host using Colima (k3s) as the
#              Kubernetes provider.
# Parameters:
#   $1 - Mode of operation: "deploy", "cleanapps", or "cleanall"
#------------------------------------------------------------------------------
env_setup_mac_cluster() {
    local mode="$1"
    if [[ "$mode" == "deploy" ]]; then
        check_resources_ok
        install_mac_k8s
        configure_mac_vm_limits
        # NOTE: configure_mac_k3s_node_ip is intentionally NOT called here.
        # The default Colima k3s setup works correctly without explicit node-ip binding.
        # The function exists and is updated for potential future use if needed.
        ensure_python_venv
        add_hosts
        check_and_load_helm_repos
        install_nginx_local_cluster
        log_section "macOS kubernetes cluster configured for $k8s_user"
        print_end_message
    elif [[ "$mode" == "cleanapps" || "$mode" == "cleanall" ]]; then
        if is_cluster_accessible; then
            # Cluster is up — delete namespaces and helm releases cleanly
            if [[ "$mode" == "cleanapps" ]]; then
                : # app deletion handled by delete_apps called from commandline.sh
            else
                log_step "Removing ingress-nginx"
                run_as_user "helm uninstall ingress-nginx -n default" >/dev/null 2>&1 || true
                log_ok
            fi
        else
            if [[ "$mode" == "cleanapps" ]]; then
                log_error "Kubernetes cluster is NOT accessible"
                exit 1
            else
                log_warn "Kubernetes cluster is not accessible — skipping namespace cleanup"
            fi
        fi
        remove_hosts
        if [[ "$mode" == "cleanall" ]]; then
            # Delete the Colima VM entirely — full wipe of k3s state and images.
            # colima delete stops the VM first if running, then removes the disk.
            local colima
            if colima=$(find_colima); then
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
        show_usage
        exit 1
    fi
}
