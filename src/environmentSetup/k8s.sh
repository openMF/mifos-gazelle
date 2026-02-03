#!/usr/bin/env bash
# kubernetes specific functions 

#------------------------------------------------------------------------------
# Checks K3s status and returns 0 for 'pass' or 1 for failure.
# based on k3s check-config output parsing and removing ANSI escape codes if any
# note this isn't used for k3s cluster health checking just installation verification
#------------------------------------------------------------------------------
function check_k3s_cluster_status {
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
function install_k3s {
    # TODO check this i.e. do we need to remove old kube config like this 
    rm -rf "$k8s_user_home/.kube" >> /dev/null 2>&1
    printf "\r==> install local k3s cluster v%s user [%s]    " "$k8s_version" "$k8s_user"
    curl -sfL https://get.k3s.io | K3S_KUBECONFIG_MODE="644" \
                            INSTALL_K3S_CHANNEL="v$k8s_version" \
                            INSTALL_K3S_EXEC=" --disable traefik " sh > /dev/null 2>&1

    if ! check_k3s_cluster_status ; then
        printf "[fail]\n"
        printf "    ** Error: k3s check-config not reporting status of pass ** \n"
        printf "    ** run sudo k3s check-config manually as user [%s] for more information   ** \n" "$k8s_user"
        exit 1
    fi

    rm -rf $kubeconfig_path
    mkdir -p "$(dirname "$kubeconfig_path")"
    chown "$k8s_user" "$(dirname "$kubeconfig_path")"
    cp /etc/rancher/k3s/k3s.yaml "$kubeconfig_path"
    chown "$k8s_user" "$kubeconfig_path"
    chmod 600 "$kubeconfig_path"

    logWithVerboseCheck "$debug" debug "k3s kubeconfig copied to $kubeconfig_path"
    printf "[ok]\n"

}

#------------------------------------------------------------------------------
# Function: deployPhHelmChartFromDir
# Description: Deploys a Helm chart from a specified directory into a given namespace.
#------------------------------------------------------------------------------
function check_nginx_running {
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
function get_ingress_ip {
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
printf "\r==> Check and load Helm repositories    "
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
  printf "            [ok]\n"
}

#------------------------------------------------------------------------------
# Description: Install NGINX ingress controller in a local cluster using Helm 
#              if not already installed. Wait for it to be running.   
#------------------------------------------------------------------------------ 
function install_nginx_local_cluster {
    printf "\r==> Installing NGINX to local cluster "
    if ! check_nginx_running; then 
        run_as_user  "helm delete ingress-nginx -n default " > /dev/null 2>&1
        run_as_user  "helm install --wait --timeout 1200s ingress-nginx ingress-nginx \
                            --repo https://kubernetes.github.io/ingress-nginx \
                            -n default -f $NGINX_VALUES_FILE"  > /dev/null 2>&1
    fi 
    if check_nginx_running; then 
        printf "              [ok]\n"
    else
        printf "** Error: Helm install of NGINX ingress controller failed, pod is not running **\n"
        exit 1
    fi
}

#------------------------------------------------------------------------------
# Install k8s related tools if not already installed
#------------------------------------------------------------------------------
function install_k8s_tools {
    printf "\r==> Checking and installing Kubernetes tools     "

    # --- NOTE ON VERSIONING ---
    # TODO 
    # Define these versions globally (or ensure they are passed in)
    # local kubectl_version="v1.30.0"
    # local helm_version="v3.14.4"

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
            if [[ "$debug" == "true" ]]; then
                echo "    $tool is already installed. Skipping."
            fi
            
            continue
        else
            #echo "Installing $tool..."
            # Installation logic
            if [[ "$tool" == "kustomize" ]]; then
                # kustomize uses a special install script
                curl -s "${tools[$tool]}" | bash > /dev/null 2>&1

            elif [[ "$tool" == "kubectl" ]]; then
                # kubectl is a direct executable download, so we save it and make it executable
                curl -s -L "${tools[$tool]}" -o ./"$tool"
                chmod +x ./"$tool"

            else
                # Install archives (kubens, kubectx, k9s, helm)
                curl -s -L "${tools[$tool]}" | tar xz -C . > /dev/null 2>&1
                if [[ "$tool" == "helm" ]]; then
                    # Helm has a nested structure after extraction
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
                if [[ "$debug" == "true" ]]; then
                    echo "    $tool installed successfully."
                fi
            else
                echo "Error: $tool installation failed."
            fi
        fi
    done
    printf "   [ok]\n"
}


#------------------------------------------------------------------------------
# Function : report_cluster_info
# Description: Reports basic information about the Kubernetes cluster.
#------------------------------------------------------------------------------
function report_cluster_info {
    #export KUBECONFIG="$kubeconfig_path"
    num_nodes=$(kubectl get nodes --no-headers | wc -l)
    k8s_version=$(kubectl version | grep Server | awk '{print $3}')
    printf "\r==> Cluster is available.\n"
    printf "    Number of nodes: %s\n" "$num_nodes"
    printf "    Kubernetes version: %s\n" "$k8s_version"
}
