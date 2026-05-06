#!/usr/bin/env bash
# kubernetes specific functions 

#------------------------------------------------------------------------------
# Checks K3s status and returns 0 for 'pass' or 1 for failure.
# based on k3s check-config output parsing and removing ANSI escape codes if any
# note this isn't used for k3s cluster health checking just installation verification
#------------------------------------------------------------------------------
check_k3s_cluster_status() {
    status=$(
        k3s check-config 2>/dev/null | 
        perl -ne 's/\e\[[0-9;]*m//g; if (/STATUS: (pass|fail)/) { print "$1\n" }' | 
        tr -d '[:space:]'
    )
    if [[ "$status" == "pass" ]]; then
        return 0 # Success
    else
        return 1 # Failure
    fi
}

#------------------------------------------------------------------------------
# Install k3s lightweight Kubernetes cluster
#------------------------------------------------------------------------------
install_k3s() {
    # TODO check this i.e. do we need to remove old kube config like this 
    rm -rf "$k8s_user_home/.kube" >> /dev/null 2>&1
    log_step "install local k3s cluster v${k8s_version} user [${k8s_user}]"
    curl -sfL https://get.k3s.io | K3S_KUBECONFIG_MODE="644" \
                            INSTALL_K3S_CHANNEL="v$k8s_version" \
                            INSTALL_K3S_EXEC=" --disable traefik " sh > /dev/null 2>&1

    if ! check_k3s_cluster_status ; then
        log_failed
        log_error "k3s check-config not reporting status of pass"
        log_error "run sudo k3s check-config manually as user [$k8s_user] for more information"
        exit 1
    fi

    rm -rf $kubeconfig_path
    mkdir -p "$(dirname "$kubeconfig_path")"
    chown "$k8s_user" "$(dirname "$kubeconfig_path")"
    cp /etc/rancher/k3s/k3s.yaml "$kubeconfig_path"
    chown "$k8s_user" "$kubeconfig_path"
    chmod 600 "$kubeconfig_path"

    log_with_verbose_check "$debug" debug "k3s kubeconfig copied to $kubeconfig_path"

    # Increase inotify and file-descriptor limits so Java/Spring-Boot pods (zeebe,
    # bulk-processor, etc.) don't hit "too many open files" / fsnotify errors.
    # Write to sysctl.d so the settings survive reboots.
    log_step "Configuring kernel limits for k3s (inotify / file descriptors)"
    tee /etc/sysctl.d/99-k3s.conf > /dev/null <<'EOF'
fs.inotify.max_user_watches=1048576
fs.inotify.max_user_instances=8192
fs.file-max=2097152
EOF
    sysctl --system > /dev/null 2>&1
    log_ok

}

#------------------------------------------------------------------------------
# Function: check_nginx_running
# Description: Returns 0 if the NGINX ingress pod is running, 1 otherwise.
#------------------------------------------------------------------------------
check_nginx_running() {
    nginx_pod_name=$(run_as_user "kubectl get pods -n default --no-headers -o custom-columns=\":metadata.name\"" | grep nginx | head -n 1)
    if [ -z "$nginx_pod_name" ]; then
        return 1
    fi
    pod_status=$(run_as_user "kubectl get pod -n default \"$nginx_pod_name\" -o jsonpath='{.status.phase}'")
    if [ "$pod_status" == "Running" ]; then
        return 0
    else
        return 1
    fi
}

#------------------------------------------------------------------------------
# Function: get_ingress_ip
# Description: Retrieves and displays the external IP or hostname of the NGINX Ingress Controller
#------------------------------------------------------------------------------
get_ingress_ip() {
    ingress_ip=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [ -z "$ingress_ip" ]; then
        ingress_ip=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
        if [ -z "$ingress_ip" ]; then
            ingress_ip="not-assigned"
        fi
    fi
    printf "\r==> NGINX Ingress Controller external address: %s\n" "$ingress_ip"
    if [[ "$ingress_ip" == "not-assigned" ]]; then
        printf "    Note: No external IP or hostname assigned yet. It may take a few minutes for the cloud provider to assign one.\n"
        printf "    Run 'kubectl get svc -n ingress-nginx ingress-nginx-controller' to check the status.\n"
    else
        printf "    Configure DNS to point Mifos Gazelle domains (e.g., *.mifos.gazelle.test) to %s\n" "$ingress_ip"
    fi
}

#------------------------------------------------------------------------------
# Function: check_and_load_helm_repos
# Description: Ensures a fixed set of Helm repos exist and are up-to-date.
#              Adds missing repos and updates existing ones if URLs differ.
#              minimises updates and network traffic 
#------------------------------------------------------------------------------
check_and_load_helm_repos() {
log_step "Check and load Helm repositories"
  local updated=false

  # Gazelle Repos List (name and URL)
  local repos=(
    "kokuwa https://kokuwaio.github.io/helm-charts"
    "codecentric https://codecentric.github.io/helm-charts"
    "bitnami https://charts.bitnami.com/bitnami"
    "cowboysysop https://cowboysysop.github.io/charts/"
    "redpanda-data https://charts.redpanda.com/"
    "ingress-nginx https://kubernetes.github.io/ingress-nginx"
  )

  # Cache repo list once
  local repo_list_yaml
  repo_list_yaml=$(helm repo list -o yaml 2>/dev/null)

  # Loop over known repos
  for entry in "${repos[@]}"; do
    local repo_name repo_url existing_url
    repo_name=$(echo "$entry" | awk '{print $1}')
    repo_url=$(echo "$entry" | awk '{print $2}')

    # Extract existing URL from cached YAML
    existing_url=$(echo "$repo_list_yaml" | grep -A1 "^- name: $repo_name" | grep "url:" | awk '{print $2}')
    if [[ -z "$existing_url" ]]; then
      if ! run_as_user "helm repo add $repo_name $repo_url" >/dev/null 2>&1; then
        echo "  ** Error: Failed to add Helm repo '$repo_name' ($repo_url)" >&2
        exit 1
      fi
      updated=true

    elif [[ "$existing_url" != "$repo_url" ]]; then
      echo "  ** Warning: Helm repo '$repo_name' URL mismatch." >&2
      echo "     Found: $existing_url" >&2
      echo "     Expected: $repo_url" >&2

      if ! run_as_user "helm repo remove $repo_name" >/dev/null 2>&1; then
        echo "  ** Error: Failed to remove mismatched Helm repo '$repo_name'" >&2
        return 1
      fi

      if ! run_as_user "helm repo add $repo_name $repo_url" >/dev/null 2>&1; then
        echo "  ** Error: Failed to re-add Helm repo '$repo_name' ($repo_url)" >&2
        return 1
      fi
      updated=true
    fi
  done

  # Refresh all repos once if needed
  if [[ "$updated" == true ]]; then
    if ! run_as_user "helm repo update" >/dev/null 2>&1; then
      echo "  ** Error: Failed to update Helm repos" >&2
      exit 1
    fi
  fi
  log_ok
}

#------------------------------------------------------------------------------
# Description: Install NGINX ingress controller in a local cluster using Helm 
#              if not already installed. Wait for it to be running.   
#------------------------------------------------------------------------------ 
install_nginx_local_cluster() {
    log_step "Installing NGINX ingress controller"
    if ! check_nginx_running; then 
        run_as_user  "helm delete ingress-nginx -n default " > /dev/null 2>&1
        run_as_user  "helm install --wait --timeout 1200s ingress-nginx ingress-nginx \
                            --repo https://kubernetes.github.io/ingress-nginx \
                            -n default -f $NGINX_VALUES_FILE"  > /dev/null 2>&1
    fi 
    if check_nginx_running; then 
        log_ok
    else
        log_failed "Helm install of NGINX ingress controller failed, pod is not running"
        exit 1
    fi
}

#------------------------------------------------------------------------------
# Install k8s related tools if not already installed
#------------------------------------------------------------------------------
install_k8s_tools() {
    log_step "Checking and installing Kubernetes tools"

    # macOS: use Homebrew. kubectl, docker, and docker-compose are installed here;
    # Colima does not bundle host-side binaries the way Rancher Desktop did.
    if [[ "$(uname -s)" == "Darwin" ]]; then
        ensure_homebrew
        local mac_tools=(helm k9s kubectx kustomize kubectl docker docker-compose socket_vmnet)
        for tool in "${mac_tools[@]}"; do
            local needs_install=false
            if ! command -v "$tool" &>/dev/null; then
                needs_install=true
            elif ! "$tool" version &>/dev/null && ! "$tool" --version &>/dev/null; then
                # Binary exists but fails to execute (e.g. Linux ELF on macOS) — remove and reinstall
                printf "\n    Replacing non-native '%s' binary with Homebrew version...\n" "$tool"
                rm -f "$(command -v "$tool")"
                needs_install=true
            fi
            if [[ "$needs_install" == true ]]; then
                run_brew install "$tool" >/dev/null 2>&1
            fi
            # Ensure the binary is linked into /opt/homebrew/bin — brew install
            # can leave a formula in a broken-linked state if a previous tool
            # (OrbStack, Rancher Desktop) removed its symlink without telling brew.
            run_brew unlink "$tool" >/dev/null 2>&1 || true
            run_brew link --overwrite "$tool" >/dev/null 2>&1 || true
        done
        log_ok
        return 0
    fi

    # For local clusters, match kubectl to the configured k3s version so there
    # is no version skew between the client binary and the server.
    if [[ "${environment:-local}" == "local" && -n "$k8s_version" ]]; then
        KUBECTL_VERSION="v${k8s_version}.0"
    fi

    # Detect architecture
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH_TYPE="amd64" ;;
        aarch64|arm64) ARCH_TYPE="arm64" ;;
        *) echo "Unsupported architecture: $ARCH"; echo "error ***  Wrong CPU Type ****" ; exit 1 ;;
    esac

    # Array of tools and their installation details
    declare -A tools=(
        # kubectl uses the official download site, which provides the executable directly.
        ["kubectl"]="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH_TYPE}/kubectl"
        ["kubens"]="https://github.com/ahmetb/kubectx/releases/download/v0.9.4/kubens_v0.9.4_linux_${ARCH_TYPE}.tar.gz"
        ["kubectx"]="https://github.com/ahmetb/kubectx/releases/download/v0.9.4/kubectx_v0.9.4_linux_${ARCH_TYPE}.tar.gz"
        ["kustomize"]="https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"
        ["k9s"]="https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_${ARCH_TYPE}.tar.gz"
        ["helm"]="https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH_TYPE}.tar.gz"
    )

    for tool in "${!tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            # For kubectl, also verify the installed version matches the required version
            if [[ "$tool" == "kubectl" ]]; then
                installed_ver=$(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":"[^"]*"' | head -1 | cut -d'"' -f4)
                if [[ "$installed_ver" != "$KUBECTL_VERSION" ]]; then
                    log_with_verbose_check "$debug" "$INFO" "kubectl $installed_ver installed but $KUBECTL_VERSION required — reinstalling"
                else
                    log_with_verbose_check "$debug" "$DEBUG" "$tool $installed_ver is already installed. Skipping."
                    continue
                fi
            else
                log_with_verbose_check "$debug" "$DEBUG" "$tool is already installed. Skipping."
                continue
            fi
        fi
        # Install or reinstall the tool
        if [[ "$tool" == "kustomize" ]]; then
            curl -s "${tools[$tool]}" | bash > /dev/null 2>&1

        elif [[ "$tool" == "kubectl" ]]; then
            curl -s -L "${tools[$tool]}" -o ./"$tool"
            chmod +x ./"$tool"

        else
            # Install archives (kubens, kubectx, k9s, helm)
            curl -s -L "${tools[$tool]}" | tar xz -C . > /dev/null 2>&1
            if [[ "$tool" == "helm" ]]; then
                mv linux-${ARCH_TYPE}/helm ./"$tool" > /dev/null 2>&1
                rm -rf linux-${ARCH_TYPE} > /dev/null 2>&1
            fi
        fi

        # Move the resulting executable(s) to the bin path
        if [[ "$tool" != "kustomize" ]]; then
            mv ./"$tool" /usr/local/bin > /dev/null 2>&1
        fi

        # Verify installation
        if command -v "$tool" >/dev/null 2>&1; then
            log_with_verbose_check "$debug" "$DEBUG" "$tool installed successfully."
        else
            echo "Error: $tool installation failed."
        fi
    done
    log_ok
}


#------------------------------------------------------------------------------
# Function : report_cluster_info
# Description: Reports basic information about the Kubernetes cluster.
#------------------------------------------------------------------------------
report_cluster_info() {
    #export KUBECONFIG="$kubeconfig_path"
    num_nodes=$(kubectl get nodes --no-headers | wc -l)
    k8s_version=$(kubectl version | grep Server | awk '{print $3}')
    printf "\r==> Cluster is available.\n"
    printf "    Number of nodes: %s\n" "$num_nodes"
    printf "    Kubernetes version: %s\n" "$k8s_version"
}
