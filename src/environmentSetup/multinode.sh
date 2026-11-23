#!/usr/bin/env bash
# multinode.sh -- Join an additional node to an existing local k3s cluster, and
# optionally dedicate it to a role (e.g. "openg2p") via a taint + label so only
# workloads that explicitly tolerate that role land there.
#
# This does NOT decide which physical machine should get which role based on
# RAM/CPU — different users will have different hardware (e.g. a 16GB Pi 5 and
# an 8GB Pi 5, not two identical boards), so that judgment call is left to the
# operator via -N/-r. It does print each node's capacity after joining so that
# call can be made with real numbers instead of a guess.

#------------------------------------------------------------------------------
# Function: env_join_node_main
# Description: Entry point for `setup-env.sh -m join`. Must be run on the
#              machine that is already the k3s server. SSHes to the target
#              node, installs a matching-version k3s agent pointed at this
#              server, waits for it to register Ready, and (if -r was given)
#              tags it with a dedicated-role taint + label.
#------------------------------------------------------------------------------
env_join_node_main() {
    if ! is_local_cluster_installed; then
        log_error "No local k3s installation found on this machine."
        log_error "'join' adds a node to an EXISTING server — run 'sudo $0' (setup mode) here first."
        exit 1
    fi
    if [[ -z "${join_node_host:-}" ]]; then
        log_error "join mode requires -N <node-host> (the SSH-reachable IP/hostname of the node to join)"
        exit 1
    fi

    join_ssh_user="${join_ssh_user:-$k8s_user}"
    local ssh_opts=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10)
    [[ -n "${join_identity_file:-}" ]] && ssh_opts+=(-i "$join_identity_file")

    _join_ssh() { sudo -u "$k8s_user" ssh "${ssh_opts[@]}" "$join_ssh_user@$join_node_host" "$@"; }

    log_step "Checking SSH connectivity to $join_ssh_user@$join_node_host"
    if ! _join_ssh "true" 2>/dev/null; then
        log_failed
        log_error "Cannot SSH to $join_ssh_user@$join_node_host. Check -N/-U/-i and that the target is reachable and key-authorized."
        exit 1
    fi
    log_ok

    log_step "Checking target architecture matches this server"
    local local_arch remote_arch
    local_arch=$(uname -m)
    remote_arch=$(_join_ssh "uname -m" 2>/dev/null)
    if [[ -z "$remote_arch" ]]; then
        log_failed; log_error "Could not determine target architecture."; exit 1
    fi
    if [[ "$local_arch" != "$remote_arch" ]]; then
        log_failed
        log_error "Architecture mismatch: this server is $local_arch, target node is $remote_arch. k3s requires matching architectures to join a cluster."
        exit 1
    fi
    log_ok

    local remote_hostname
    remote_hostname=$(_join_ssh "hostname" 2>/dev/null)
    if [[ -z "$remote_hostname" ]]; then
        log_error "Could not determine hostname of target node."
        exit 1
    fi

    if kubectl get node "$remote_hostname" >/dev/null 2>&1; then
        log_with_verbose_check "$debug" "$INFO" "Node '$remote_hostname' is already part of the cluster — skipping k3s agent install, only (re)applying role below."
    else
        log_step "Determining this server's advertised IP"
        local server_ip
        server_ip=$(kubectl get nodes -l node-role.kubernetes.io/control-plane \
            -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null \
            | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
        if [[ -z "$server_ip" ]]; then
            log_failed; log_error "Could not determine this server's control-plane IP."; exit 1
        fi
        log_ok

        log_step "Fetching k3s join token"
        local join_token
        join_token=$(sudo cat /var/lib/rancher/k3s/server/node-token 2>/dev/null)
        if [[ -z "$join_token" ]]; then
            log_failed; log_error "Could not read /var/lib/rancher/k3s/server/node-token (are you root/sudo?)"; exit 1
        fi
        log_ok

        log_step "Installing k3s agent v${k8s_version} on $remote_hostname ($join_node_host)"
        if ! _join_ssh "
            set -e
            curl -sfL https://get.k3s.io | sudo INSTALL_K3S_CHANNEL='v${k8s_version}' \
                K3S_URL='https://${server_ip}:6443' \
                K3S_TOKEN='${join_token}' sh -
            sudo tee /etc/sysctl.d/99-k3s.conf > /dev/null <<'EOF'
fs.inotify.max_user_watches=1048576
fs.inotify.max_user_instances=8192
fs.file-max=2097152
EOF
            sudo sysctl --system > /dev/null 2>&1
        " > /dev/null 2>/tmp/gazelle-join-remote.log; then
            log_failed
            log_error "Remote k3s agent install failed on $join_node_host. Details: /tmp/gazelle-join-remote.log (on this machine)."
            exit 1
        fi
        log_ok

        log_step "Waiting for node '$remote_hostname' to register as Ready"
        local waited=0
        until kubectl get node "$remote_hostname" 2>/dev/null | grep -qw "Ready"; do
            sleep 3
            waited=$((waited + 3))
            if [[ $waited -ge 180 ]]; then
                log_failed
                log_error "Node '$remote_hostname' did not become Ready within 180s."
                log_error "Check: kubectl get nodes   and   ssh $join_ssh_user@$join_node_host sudo systemctl status k3s-agent"
                exit 1
            fi
        done
        log_ok
    fi

    if [[ -n "${join_role:-}" ]]; then
        log_step "Dedicating '$remote_hostname' to role '$join_role' (taint + label)"
        kubectl label node "$remote_hostname" "dedicated=${join_role}" --overwrite > /dev/null
        kubectl taint node "$remote_hostname" "dedicated=${join_role}:NoSchedule" --overwrite > /dev/null
        log_ok
    fi

    log_section "Node '$remote_hostname' joined"
    report_cluster_info

    # Print capacity for every node so the operator can judge whether the role
    # assignment actually makes sense on THEIR hardware — this script does not
    # guess that for you (see file header).
    printf "\n    Node capacity:\n"
    kubectl get nodes -o custom-columns='NAME:.metadata.name,ROLE:.metadata.labels.dedicated,MEM:.status.capacity.memory,CPU:.status.capacity.cpu' 2>/dev/null \
        | sed 's/^/      /'

    if [[ -n "${join_role:-}" ]]; then
        printf "\n    '%s' now only accepts workloads that tolerate dedicated=%s:NoSchedule.\n" "$remote_hostname" "$join_role"
        printf "    To pin a Helm chart's pods to this role, add to its values.yaml:\n"
        printf "      nodeSelector: { dedicated: %s }\n" "$join_role"
        printf "      tolerations: [{ key: dedicated, operator: Equal, value: %s, effect: NoSchedule }]\n" "$join_role"
    fi
}
