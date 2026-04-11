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
        if ! brew_available; then
            printf "\n** Error: Homebrew is required on macOS. Install from https://brew.sh **\n"
            exit 1
        fi
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
# Function: add_hosts   
# Description: Updates the local /etc/hosts file with entries for Mifos Gazelle services when using a local cluster.
#------------------------------------------------------------------------------
function add_hosts {
    if [[ "$environment" == "local" || "$environment" == "mac" ]]; then
        printf "==> Mifos-gazelle: update local hosts file  "
        
        # Use GAZELLE_DOMAIN variable, with fallback to default
        DOMAIN="${GAZELLE_DOMAIN:-mifos.gazelle.test}"
        
        VNEXTHOSTS=( mongohost.$DOMAIN mongo-express.$DOMAIN \
        vnextadmin.$DOMAIN elasticsearch.$DOMAIN kibana.$DOMAIN redpanda-console.$DOMAIN \
        mongoexpress.$DOMAIN fspiop.$DOMAIN bluebank.$DOMAIN greenbank.$DOMAIN  )
        
        PHEEHOSTS=( ops.$DOMAIN ops-bk.$DOMAIN \
        bulk-processor.$DOMAIN connector-bulk.$DOMAIN messagegateway.$DOMAIN \
        minio-console.$DOMAIN bill-pay.$DOMAIN channel.$DOMAIN \
        channel-gsma.$DOMAIN crm.$DOMAIN mockpayment.$DOMAIN \
        mojaloop.$DOMAIN identity-mapper.$DOMAIN vouchers.$DOMAIN \
        zeebeops.$DOMAIN zeebe-operate.$DOMAIN zeebe-gateway.$DOMAIN \
        notifications.$DOMAIN )
        
        MIFOSXHOSTS=( mifos.$DOMAIN )
        
        ALLHOSTS=( "127.0.0.1" "localhost" "${MIFOSXHOSTS[@]}" "${PHEEHOSTS[@]}" "${VNEXTHOSTS[@]}" )
        export ENDPOINTS=`echo ${ALLHOSTS[*]}`
        perl -pi -e 's/^(127\.0\.0\.1\s+)(.*)/$1localhost/' /etc/hosts
        perl -p -i.bak -e 's/127\.0\.0\.1.*localhost.*$/$ENV{ENDPOINTS} /' /etc/hosts
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
        add_hosts

        if ! is_local_cluster_installed; then
            install_k3s
            check_and_load_helm_repos
            install_nginx_local_cluster
            $UTILS_DIR/install-k9s.sh > /dev/null 2>&1
        fi
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
        print_end_message_delete
    else
        showUsage
        exit 1
    fi
}   

#------------------------------------------------------------------------------
# Function: _wait_for_k8s
# Description: Polls until the cluster is accessible or timeout is reached.
# Parameters:
#   $1 - timeout in seconds (default 180)
#------------------------------------------------------------------------------
function _wait_for_k8s {
    local timeout="${1:-180}"
    local waited=0
    while ! is_cluster_accessible && [[ $waited -lt $timeout ]]; do
        sleep 5; (( waited += 5 ))
        printf "\r    Waiting for Rancher Desktop Kubernetes (%ds/%ds)..." "$waited" "$timeout"
    done
    printf "\n"
    is_cluster_accessible
}

#------------------------------------------------------------------------------
# Function: install_mac_k8s
# Description: Ensures Rancher Desktop (k3s) is running on macOS.
#              Rancher Desktop is the only supported provider — it uses k3s,
#              matching the Ubuntu environment and avoiding image pull issues.
#              Errors if another Kubernetes provider is found running.
#------------------------------------------------------------------------------
#------------------------------------------------------------------------------
# Function: _find_rdctl
# Description: Locates the rdctl binary at known macOS install paths.
#              Rancher Desktop puts rdctl inside the app bundle and symlinks
#              it to ~/.rd/bin, but neither is on PATH when running via sudo.
#------------------------------------------------------------------------------
function _find_rdctl {
    local user_home
    user_home=$(eval echo "~$k8s_user")
    for candidate in \
        "$user_home/.rd/bin/rdctl" \
        "/Applications/Rancher Desktop.app/Contents/Resources/resources/darwin/bin/rdctl" \
        "/usr/local/bin/rdctl" \
        "/opt/homebrew/bin/rdctl"; do
        if [[ -x "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

#------------------------------------------------------------------------------
# Function: _start_rancher_desktop
# Description: Starts Rancher Desktop via rdctl with standard Gazelle settings.
#------------------------------------------------------------------------------
function _start_rancher_desktop {
    local rdctl
    if ! rdctl=$(_find_rdctl); then
        printf "** Error: rdctl not found. Rancher Desktop may not have installed correctly.\n"
        exit 1
    fi
    sudo -u "$k8s_user" "$rdctl" start \
        --application.start-in-background \
        --kubernetes.enabled \
        --kubernetes.version "1.30.0" \
        --container-engine.name containerd \
        --virtual-machine.memory-in-gb 16 \
        --virtual-machine.number-cpus 4
}

function install_mac_k8s {
    printf "\r==> Checking macOS Kubernetes provider\n"

    # If cluster is accessible, verify it is Rancher Desktop
    if is_cluster_accessible; then
        local current_context
        current_context=$(su - "$k8s_user" -c "kubectl config current-context" 2>/dev/null)
        if [[ "$current_context" != "rancher-desktop" ]]; then
            printf "** Error: A Kubernetes cluster is already running but it is not Rancher Desktop.\n"
            printf "   Current context: %s\n" "$current_context"
            printf "   mifos-gazelle requires Rancher Desktop on macOS.\n"
            printf "   Please stop the other provider and re-run.\n"
            exit 1
        fi
        printf "    Rancher Desktop Kubernetes is ready        [ok]\n"
        return 0
    fi

    # Rancher Desktop installed but not running — start it
    if [[ -d "/Applications/Rancher Desktop.app" ]]; then
        printf "    Rancher Desktop found, starting...\n"
        _start_rancher_desktop
        if _wait_for_k8s 180; then
            printf "    Rancher Desktop Kubernetes is ready        [ok]\n"
            return 0
        fi
        printf "** Error: Rancher Desktop did not become ready within 3 minutes.\n"
        printf "   Open Rancher Desktop and check for errors.\n"
        exit 1
    fi

    # Not installed — install via Homebrew then start
    printf "    Rancher Desktop not found. Installing via Homebrew...\n"
    if ! brew_available; then
        printf "** Error: Homebrew is required. Install from https://brew.sh **\n"
        exit 1
    fi
    if ! sudo -u "$k8s_user" brew install --cask rancher; then
        printf "** Error: Rancher Desktop installation failed.\n"
        exit 1
    fi
    printf "    Configuring and starting Rancher Desktop (this may take a few minutes)...\n"
    _start_rancher_desktop
    if ! _wait_for_k8s 180; then
        printf "** Error: Rancher Desktop did not become ready within 3 minutes.\n"
        exit 1
    fi
    printf "    Rancher Desktop Kubernetes is ready        [ok]\n"
}

#------------------------------------------------------------------------------
# Function: env_setup_mac_cluster
# Description: Sets up Gazelle on a macOS host using Rancher Desktop (k3s) as
#              the preferred Kubernetes provider, with Docker Desktop as fallback.
# Parameters:
#   $1 - Mode of operation: "deploy", "cleanapps", or "cleanall"
#------------------------------------------------------------------------------
function env_setup_mac_cluster {
    local mode="$1"
    if [[ "$mode" == "deploy" ]]; then
        check_resources_ok
        install_mac_k8s
        add_hosts
        check_and_load_helm_repos
        install_nginx_local_cluster
        printf "\r==> macOS kubernetes cluster configured for %s\n" "$k8s_user"
        print_end_message
    elif [[ "$mode" == "cleanapps" || "$mode" == "cleanall" ]]; then
        if ! is_cluster_accessible; then
            printf "** Error: Kubernetes cluster is NOT accessible\n\n"
            exit 1
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