#!/usr/bin/env bash

function check_arch_ok {
    if [[ ! "$k8s_arch" == "x86_64" ]]; then
        printf " **** Warning : mifos-gazelle only works properly with x86_64 today but vNext should be ok *****\n"
    fi
}

function check_resources_ok {
    # Get the total amount of installed RAM in GB
    total_ram=$(free -g | awk '/^Mem:/{print $2}')
    # Get the current free space on the root filesystem in GB
    free_space=$(df -BG ~ | awk '{print $4}' | tail -n 1 | sed 's/G//')

    # Check RAM
    if [[ "$total_ram" -lt "$MIN_RAM" ]]; then
        printf " ** Error : mifos-gazelle currently requires $MIN_RAM GBs to run properly \n"
        printf "    Please increase RAM available before trying to run mifos-gazelle \n"
        exit 1
    fi
    # Check free space
        if [[  "$free_space" -lt "$MIN_FREE_SPACE" ]] ; then
        printf " ** Warning : mifos-gazelle currently requires %sGBs free storage in %s home directory  \n"  "$MIN_FREE_SPACE" "$k8s_user"
        printf "    but only found %sGBs free storage \n"  "$free_space"
        printf "    mifos-gazelle installation will continue , but beware it might fail later due to insufficient storage \n"
    fi
}

function checkHelmandKubectl {
     # Check if Helm is installed
    if ! command -v helm &>/dev/null; then
        echo "Helm is not installed. Please install Helm first."
        exit 1
    fi

    # Check if kubectl is installed
    if ! command -v kubectl &>/dev/null; then
        echo "kubectl is not installed. Please install kubectl first."
        exit 1
    fi
} 

function set_user {
  # set the k8s_user
#   k8s_user=`whoami | cut -d " " -f1`
    logWithVerboseCheck $debug info "k8s user is $k8s_user"
}

function k8s_already_installed {
    if [[ -f "/usr/local/bin/k3s" ]]; then
        printf "==>  k3s is already installed **\n"
        return 0
    fi
    #check to ensure microk8s isn't already installed when installing k3s
    if [[ -f "/snap/bin/microk8s" ]]; then
        printf "** warning , microk8s is already installed, using existing deployment  **\n"
        return 0 
    fi
    return 1
}

function set_linux_os_distro {

    LINUX_VERSION="Unknown"
    if [ -x "/usr/bin/lsb_release" ]; then
        LINUX_OS=`lsb_release --d | perl -ne 'print  if s/^.*Ubuntu.*(\d+).(\d+).*$/Ubuntu/' `
        LINUX_VERSION=`/usr/bin/lsb_release --d | perl -ne 'print $&  if m/(\d+)/' `
    else
        LINUX_OS="Untested"
    fi
    printf "\r==> Linux OS is [%s] " "$LINUX_OS"
}

function check_os_ok {
    printf "\r==> checking OS and kubernetes distro is tested with mifos-gazelle scripts\n"
    set_linux_os_distro

    if [[ ! $LINUX_OS == "Ubuntu" ]]; then
        printf "** Error , Mifos Gazelle is only tested with Ubuntu OS at this time   **\n"
        exit 1
    fi
}

function install_prerequisites {
    printf "\n\r==> Install any OS prerequisites , tools &  updates  ...\n"
    if [[ $LINUX_OS == "Ubuntu" ]]; then
        printf "\rapt update \n"
        apt update > /dev/null 2>&1

        if [[ $k8s_distro == "microk8s" ]]; then
            printf "   install snapd\n"
            apt install snapd -y > /dev/null 2>&1
        fi

      # Check if Docker is installed
      if ! command -v docker &> /dev/null; then
          logWithVerboseCheck $debug debug "Docker is not installed. Installing Docker..."

          # Update package index and install prerequisites
          sudo apt update >> /dev/null 2>&1
          sudo apt install -y apt-transport-https ca-certificates curl software-properties-common >> /dev/null 2>&1

          # Add Docker GPG key
          curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg >> /dev/null 2>&1

          # Add Docker repository
          echo "deb [signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >> /dev/null 2>&1

          # Update package index again and install Docker
          sudo apt update >> /dev/null 2>&1
          sudo apt install -y docker-ce docker-ce-cli containerd.io >> /dev/null 2>&1

          # Add your user to the docker group (optional)
          sudo usermod -aG docker $USER
          
          printf "ok \n"
      else
          logWithVerboseCheck $debug debug "Docker is already installed.\n"
      fi

      # Check if nc (netcat) is installed
      if ! command -v nc &> /dev/null; then
          logWithVerboseCheck $debug debug "nc (netcat) is not installed. Installing..."

          # Update package manager repositories and install nc
          apt-get update >> /dev/null 2>&1
          apt-get install -y netcat >> /dev/null 2>&1
          
          printf "ok\n"
      else
          logWithVerboseCheck $debug debug "nc (netcat) is already installed.\n"
      fi

      # Check if jq is installed  
      if ! command -v jq &> /dev/null; then
          logWithVerboseCheck $debug debug "jq is not installed. Installing ..."
          sudo apt-get update >> /dev/null 2>&1
          sudo apt-get -y install jq >> /dev/null 2>&1

          printf "ok\n"
      else
          logWithVerboseCheck $debug debug "jq is already installed\n"
      fi
    fi


}

function add_hosts {
    printf "==> Mifos-gazelle : update hosts file \n"
    VNEXTHOSTS=( mongohost.mifos.gazelle.test mongo-express.mifos.gazelle.test \
                 vnextadmin.mifos.gazelle.test kafkaconsole.mifos.gazelle.test elasticsearch.mifos.gazelle.test redpanda-console.mifos.gazelle.test \
                 fspiop.mifos.gazelle.test bluebank.mifos.gazelle.test greenbank.mifos.gazelle.test \
                 bluebank-specapi.mifos.gazelle.test greenbank-specapi.mifos.gazelle.test  ) 

    PHEEHOSTS=(  ops.mifos.gazelle.test ops-bk.mifos.gazelle.test \
                 bulk-connector.mifos.gazelle.test messagegateway.mifos.gazelle.test \
                 minio-console.mifos.gazelle.test  \
                 bill-pay.mifos.gazelle.test channel.mifos.gazelle.test \
                 channel-gsma.mifos.gazelle.test crm.mifos.gazelle.test \
                 mockpayment.mifos.gazelle.test mojaloop.mifos.gazelle.test \
                 identity-mapper.mifos.gazelle.test vouchers.mifos.gazelle.test \
                 zeebeops.mifos.gazelle.test zeebe-operate.mifos.gazelle.test zeebe-gateway.mifos.gazelle.test \
                 elastic-phee.mifos.gazelle.test kibana-phee.mifos.gazelle.test \
                 notifications.mifos.gazelle.test )  

    MIFOSXHOSTS=( mifos.mifos.gazelle.test fineract.mifos.gazelle.test ) 

    ALLHOSTS=( "127.0.0.1" "localhost" "${MIFOSXHOSTS[@]}" "${PHEEHOSTS[@]}" "${VNEXTHOSTS[@]}"  )

    export ENDPOINTS=`echo ${ALLHOSTS[*]}`
    # remove any existing extra hosts from 127.0.0.1 entry in localhost 
    perl -pi -e 's/^(127\.0\.0\.1\s+)(.*)/$1localhost/' /etc/hosts

    # add all the gazelle hosts to the 127.0.0.1 localhost entry of /etc/hosts 
    perl -p -i.bak -e 's/127\.0\.0\.1.*localhost.*$/$ENV{ENDPOINTS} /' /etc/hosts
    # TODO check the ping actually works > suggest cloud network rules if it doesn't
    #      also for cloud VMs might need to use something other than curl e.g. netcat ?
    # ping  -c 2 account-lookup-service-admin.mifos.gazelle.test
}

function set_k8s_distro {
    if [ -z ${k8s_distro+x} ]; then
        k8s_distro=$DEFAULT_K8S_DISTRO
        printf "==> Using default kubernetes distro [%s]\n" "$k8s_distro"
    else
        k8s_distro=`echo "$k8s_distro" | perl -ne 'print lc'`
        if [[ "$k8s_distro" == "microk8s" || "$k8s_distro" == "k3s" ]]; then
            printf "\r==> kubernetes distro set to [%s] \n" "$k8s_distro"
        else
            printf "** Error : invalid kubernetes distro specified. Valid options are microk8s or k3s \n"
            exit 1
        fi
    fi
}

function print_current_k8s_releases {
    printf "          Current Kubernetes releases are : "
    for i in "${K8S_CURRENT_RELEASE_LIST[@]}"; do
        printf " [v%s]" "$i"
    done
    printf "\n"
}

function set_k8s_version {
    # printf "========================================================================================\n"
    # printf " set the k8s version to install  \n"
    # printf "========================================================================================\n\n"
    # Users who want to run non-current versions of kubernetes will need to use earlier releases of mifos-gazelle and
    # and be aware that these are not being actively maintained
    if [ ! -z ${k8s_user_version+x} ] ; then
        # strip off any leading characters
        k8s_user_version=`echo $k8s_user_version |  tr -d A-Z | tr -d a-z `
        for i in "${K8S_CURRENT_RELEASE_LIST[@]}"; do
            if  [[ "$k8s_user_version" == "$i" ]]; then
                CURRENT_RELEASE=true
                break
            fi
        done
        if [[ $CURRENT_RELEASE == true ]]; then
            K8S_VERSION=$k8s_user_version
        else
            printf "** Error: The specified kubernetes release [ %s ] is not a current release \n" "$k8s_user_version"
            printf "          when using the -v flag you must specify a current supported release \n"
            print_current_k8s_releases
            printf "** \n"
            exit 1
        fi
    else
        printf "** Error: kubernetes release has not been specified with the -v flag  \n"
        printf "          you must supply the -v flag and specify a current supported release \n\n"
        showUsage
        exit 1
    fi
    printf "\r==> kubernetes version to install set to [%s] \n" "$K8S_VERSION"
}

function do_microk8s_install {
    # TODO : Microk8s can complain that This is insecure. Location: /var/snap/microk8s/2952/credentials/client.config
    printf "==> Installing Kubernetes MicroK8s & enabling tools (helm,ingress  etc) \n"

    echo "==> Microk8s Install: installing microk8s release $k8s_user_version ... "
    # ensure k8s_user has clean .kube/config
    rm -rf $k8s_user_home/.kube >> /dev/null 2>&1

    snap install microk8s --classic --channel=$K8S_VERSION/stable
    microk8s.status --wait-ready

    microk8s.enable helm3
    microk8s.enable dns
    echo "==> enable storage ... "
    microk8s.enable storage
    microk8s.enable ingress

    echo "==> add convenient aliases..."
    snap alias microk8s.kubectl kubectl
    snap alias microk8s.helm3 helm

    echo "==> add $k8s_user user to microk8s group"
    usermod -a -G microk8s $k8s_user

    # ensure .kube/config points to this new cluster and KUBECONFIG is not set in .bashrc
    perl -p -i.bak -e 's/^.*KUBECONFIG.*$//g' $k8s_user_home/.bashrc
    perl -p -i.bak -e 's/^.*KUBECONFIG.*$//g' $k8s_user_home/.bash_profile
    chown -f -R $k8s_user $k8s_user_home/.kube
    microk8s config > $k8s_user_home/.kube/config
}

function do_k3s_install {
    printf "========================================================================================\n"
    printf "Mifos-gazelle k3s install : Installing Kubernetes k3s engine and tools (helm/ingress etc) \n"
    printf "========================================================================================\n"
    # ensure k8s_user has clean .kube/config
    rm -rf $k8s_user_home/.kube >> /dev/null 2>&1
    printf "\r==> installing k3s "
    #echo $K8S_VERSION
    curl -sfL https://get.k3s.io | K3S_KUBECONFIG_MODE="644" \
                            INSTALL_K3S_CHANNEL="v$K8S_VERSION" \
                            INSTALL_K3S_EXEC=" --disable traefik " sh > /dev/null 2>&1

    # check k3s installed ok
    status=`k3s check-config 2> /dev/null | grep "^STATUS" | awk '{print $2}'  `
    if [[ "$status" -eq "pass" ]]; then
        printf "[ok]\n"
    else
        printf "** Error : k3s check-config not reporting status of pass   ** \n"
        printf "   run k3s check-config manually as user [%s] for more information   ** \n" "$k8s_user"
        exit 1
    fi

    # configure user environment to communicate with k3s kubernetes
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    sudo chown $k8s_user $KUBECONFIG
    cp /etc/rancher/k3s/k3s.yaml  $k8s_user_home/k3s.yaml
    chown $k8s_user  $k8s_user_home/k3s.yaml
    chmod 600  $k8s_user_home/k3s.yaml
    sudo chmod 600 $KUBECONFIG

    perl -p -i.bak -e 's/^.*KUBECONFIG.*$//g' $k8s_user_home/.bashrc
    echo "export KUBECONFIG=\$HOME/k3s.yaml" >>  $k8s_user_home/.bashrc
    perl -p -i.bak -e 's/^.*source .bashrc.*$//g' $k8s_user_home/.bash_profile
    perl -p  -i.bak2 -e 's/^.*export KUBECONFIG.*$//g' $k8s_user_home/.bash_profile
    echo "source .bashrc" >>   $k8s_user_home/.bash_profile
    echo "export KUBECONFIG=\$HOME/k3s.yaml" >> $k8s_user_home/.bash_profile

    # install helm
    printf "\r==> installing helm "
    helm_arch_str=""
    if [[ "$k8s_arch" == "x86_64" ]]; then
        helm_arch_str="amd64"
    elif [[ "$k8s_arch" == "aarch64" ]]; then
        helm_arch_str="arm64"
    else
        printf "** Error:  architecture not recognised as x86_64 or arm64  ** \n"
        exit 1
    fi
    rm -rf /tmp/linux-$helm_arch_str /tmp/helm.tar
    curl -L -s -o /tmp/helm.tar.gz https://get.helm.sh/helm-v$HELM_VERSION-linux-$helm_arch_str.tar.gz
    gzip -d /tmp/helm.tar.gz
    tar xf  /tmp/helm.tar -C /tmp
    mv /tmp/linux-$helm_arch_str/helm /usr/local/bin
    rm -rf /tmp/linux-$helm_arch_str
    /usr/local/bin/helm version > /dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        printf "[ok]\n"
    else
        printf "** Error : helm install seems to have failed ** \n"
        exit 1
    fi
}

function check_nginx_running {
    # Get the first nginx pod name
    nginx_pod_name=$(kubectl get pods --no-headers -o custom-columns=":metadata.name" | grep nginx | head -n 1)

    if [ -z "$nginx_pod_name" ]; then
        # No nginx pod found
        return 1
    fi
    # Check if the Nginx pod is running
    pod_status=$(kubectl get pod $nginx_pod_name -o jsonpath='{.status.phase}')
    if [ "$pod_status" == "Running" ]; then
        # nginx is running
        return 0
    else
        # nginx is not running
        return 1
    fi
}

function install_nginx () { 
    local cluster_type=$1
    local k8s_distro=$2
    #install nginx
    printf "\r==> installing nginx ingress chart and wait for it to be ready "
    if check_nginx_running; then 
        printf "[ nginx already installed and running ] \n"
        return 0 
    fi 
    # echo "\n nope cluster is not running"
    # echo "cluster_type=$cluster_type"
    # echo "k8s_distro=$k8s_distro"
    if [[ $cluster_type == "local" ]]; then 
        if [[ $k8s_distro == "microk8s" ]]; then 
            microk8s.enable ingress
            printf "[ok]\n"
        else # i.e. k3s 
            su - $k8s_user -c "helm delete ingress-nginx -n default " > /dev/null 2>&1
            su - $k8s_user -c "helm install --wait --timeout 1200s ingress-nginx ingress-nginx \
                              --repo https://kubernetes.github.io/ingress-nginx \
                              -n default -f $NGINX_VALUES_FILE" > /dev/null 2>&1
            # Check if the Nginx pod is running
            if check_nginx_running; then 
                printf "[ok]\n"
            else
                printf "** Error : helm install of nginx seems to have failed , nginx pod is not running  ** \n"
                exit 1
            fi
        fi 
    fi 
}

function install_k8s_tools {
    printf "\r==> install kubernetes tools, kubens, kubectx kustomize \n"
    curl -s -L https://github.com/ahmetb/kubectx/releases/download/v0.9.4/kubens_v0.9.4_linux_x86_64.tar.gz| gzip -d -c | tar xf -
    mv ./kubens /usr/local/bin > /dev/null 2>&1
    curl -s -L https://github.com/ahmetb/kubectx/releases/download/v0.9.4/kubectx_v0.9.4_linux_x86_64.tar.gz | gzip -d -c | tar xf -
    mv ./kubectx /usr/local/bin > /dev/null  2>&1

    # install kustomize
    curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"  | bash > /dev/null  2>&1
    mv ./kustomize /usr/local/bin > /dev/null 2>&1
}

function add_helm_repos {
    printf "\r==> add the helm repos required to install and run infrastructure for vNext, Paymenthub EE and MifosX\n"
    su - $k8s_user -c "helm repo add kiwigrid https://kiwigrid.github.io" > /dev/null 2>&1
    su - $k8s_user -c "helm repo add kokuwa https://kokuwaio.github.io/helm-charts" > /dev/null 2>&1  #fluentd
    su - $k8s_user -c "helm repo add elastic https://helm.elastic.co" > /dev/null 2>&1
    su - $k8s_user -c "helm repo add codecentric https://codecentric.github.io/helm-charts" > /dev/null 2>&1 # keycloak for TTK
    su - $k8s_user -c "helm repo add bitnami https://charts.bitnami.com/bitnami" > /dev/null 2>&1
    su - $k8s_user -c "helm repo add mojaloop http://mojaloop.io/helm/repo/" > /dev/null 2>&1
    su - $k8s_user -c "helm repo add cowboysysop https://cowboysysop.github.io/charts/" > /dev/null 2>&1  # mongo-express
    su - $k8s_user -c "helm repo add redpanda-data https://charts.redpanda.com/ " > /dev/null 2>&1   # kafka console
    su - $k8s_user -c "helm repo update" > /dev/null 2>&1
}

function configure_k8s_user_env {
    start_message="# GAZELLE_START start of config added by mifos-gazelle #"
    grep "start of config added by mifos-gazelle" $k8s_user_home/.bashrc >/dev/null 2>&1
    if [[ $? -ne 0  ]]; then
        printf "==> Adding configuration for %s to %s .bashrc\n" "$k8s_distro" "$k8s_user"
        printf "%s\n" "$start_message" >> $k8s_user_home/.bashrc
        echo "source <(kubectl completion bash)" >> $k8s_user_home/.bashrc # add autocomplete permanently to your bash shell.
        echo "alias k=kubectl " >>  $k8s_user_home/.bashrc
        echo "complete -F __start_kubectl k " >>  $k8s_user_home/.bashrc
        echo "alias ksetns=\"kubectl config set-context --current --namespace\" " >>  $k8s_user_home/.bashrc
        echo "alias ksetuser=\"kubectl config set-context --current --user\" "  >>  $k8s_user_home/.bashrc
        echo "alias cdml=\"cd $k8s_user_home/mifos-gazelle\" " >>  $k8s_user_home/.bashrc
        printf "#GAZELLE_END end of config added by mifos-gazelle #\n" >> $k8s_user_home/.bashrc
    else
        printf "\r==> Configuration for .bashrc for %s for user %s already exists ..skipping\n" "$k8s_distro" "$k8s_user"
    fi
}

function verify_user {
# ensure that the user for k8s exists
        if [ -z ${k8s_user+x} ]; then
            printf "** Error: The operating system user has not been specified with the -u flag \n"
            printf "          the user specified with the -u flag must exist and not be the root user \n"
            printf "** \n"
            exit 1
        fi

        if [[ `id -u $k8s_user >/dev/null 2>&1` == 0 ]]; then
            printf "** Error: The user specified by -u should be a non-root user ** \n"
            exit 1
        fi

        if id -u "$k8s_user" >/dev/null 2>&1 ; then
            k8s_user_home=`eval echo "~$k8s_user"`
            return
        else
            printf "** Error: The user [ %s ] does not exist in the operating system \n" $k8s_user
            printf "            please try again and specify an existing user \n"
            printf "** \n"
            exit 1
        fi
}

function delete_k8s {
    if [[ "$k8s_distro" == "microk8s" ]]; then
        printf "==> removing any existing Microk8s installation "
        snap remove microk8s > /dev/null 2>&1
        if [[ $? -eq 0  ]]; then
            printf " [ ok ] \n"
        else
            printf " [ microk8s delete failed ] \n"
            printf "** was microk8s installed ?? \n"
            printf "   if so please try running \"sudo snap remove microk8s\" manually ** \n"
        fi
    else
        printf "==> removing any existing k3s installation and helm binary"
        rm -f /usr/local/bin/helm >> /dev/null 2>&1
        /usr/local/bin/k3s-uninstall.sh >> /dev/null 2>&1
        if [[ $? -eq 0  ]]; then
            printf " [ ok ] \n"
        else
            echo -e "\n==> k3s not installed"
        fi
    fi
    # remove config from user .bashrc
    perl -i -ne 'print unless /START_GAZELLE/ .. /END_GAZELLE/'  $k8s_user_home/.bashrc
}

function checkClusterConnection {
    printf "\r==> Check the cluster is available and ready from kubectl  "
    k8s_ready=`su - $k8s_user -c "kubectl get nodes" | perl -ne 'print  if s/^.*Ready.*$/Ready/'`
    if [[ ! "$k8s_ready" == "Ready" ]]; then
        printf "** Error : kubernetes is not reachable  ** "
        exit 1
    fi
    printf "    [ ok ] \n"
}

function print_end_message {
    echo -e "\n${GREEN}============================"
    echo -e "Environment setup successful"
    echo -e "============================${RESET}\n"
}

function print_end_message_tear_down {
  echo -e "\n\n=================================================="
  echo -e "Thank you for using Mifos-gazelle cleanup successful"
  echo -e "======================================================\n\n"
  echo -e "Copyright © 2023 The Mifos Initiative"
}

function setup_k8s_cluster {
        cluster_type="$2"

        if [ -z "$cluster_type" ]; then
            printf "Cluster type not set. Defaulting to local \n"
            cluster_type="local"
        fi

        if [[ "$cluster_type" == "remote" ]]; then
            echo "Verifying connection to the remote Kubernetes cluster..."
            kubectl get pods >/dev/null 2>&1
            if [[ $? -eq 0 ]]; then
                echo "Successfully connected to the remote Kubernetes cluster."
            else
                echo "Failed to connect to the remote Kubernetes cluster. Please configure access to a remote cluster with kubectl to continue with a remote cluster."
                echo "Otherwise,rerun the script and choose local"
                exit 1
            fi
        elif [[ "$cluster_type" == "local" ]]; then
            if [[ "$k8s_distro" == "microk8s" ]]; then
                do_microk8s_install
            else
                do_k3s_install
            fi
        else
            echo "Invalid choice. Defaulting to local"
            cluster_type="local"
            if [[ "$k8s_distro" == "microk8s" ]]; then
                do_microk8s_install
            else
                do_k3s_install
            fi
        fi
}

# function deleteAppResources(){
#     deleteResourcesInNamespaceMatchingPattern "$FIN_NAMESPACE"
#     deleteResourcesInNamespaceMatchingPattern "$VNEXT_NAMESPACE"
#     deleteResourcesInNamespaceMatchingPattern "$PH_NAMESPACE"
#     deleteResourcesInNamespaceMatchingPattern "$INFRA_NAMESPACE"
#     deleteResourcesInNamespaceMatchingPattern "default"
# }

################################################################################
# MAIN
################################################################################
function envSetupMain {
    DEFAULT_K8S_DISTRO="k3s"  #only k3s is currently being tested 
    K8S_VERSION=""

    HELM_VERSION="3.12.0"  # Feb 2023
    OS_VERSIONS_LIST=( 22 24 )
    K8S_CURRENT_RELEASE_LIST=( "1.30" "1.31" )
    CURRENT_RELEASE="false"
    k8s_user_home=""
    k8s_arch=`uname -p`  # what arch
    # Set the minimum amount of RAM in GB
    MIN_RAM=4
    MIN_FREE_SPACE=30
    LINUX_OS_LIST=( "Ubuntu" )
    UBUNTU_OK_VERSIONS_LIST=(22 24)

    # ensure we are running as root
    if [ "$EUID" -ne 0 ]
    then echo "Please run as root"
    exit 1
    fi

    # Check arguments
    if [ $# -lt 1 ] ; then
        showUsage
        echo "Not enough arguments -m mode must be specified "
        exit 1
    fi

    # Process function arguments as required
    mode="$1"
    k8s_distro="$2"
    k8s_user_version="$3"
    environment="$4"

    check_arch_ok
    set_user
    verify_user

    if [[ "$mode" == "deploy" ]]  ; then
        check_resources_ok
        set_k8s_distro
        set_k8s_version
        if ! k8s_already_installed; then 
            check_os_ok # todo add check to this once tested across other OS's more fully
            install_prerequisites
            add_hosts
            setup_k8s_cluster $k8s_distro $environment
            install_nginx $environment $k8s_distro
            install_k8s_tools
            add_helm_repos
            configure_k8s_user_env
        else 
            checkHelmandKubectl # ensure things really are in place properly 
        fi
        install_nginx $environment $k8s_distro # will skip if already running
        checkClusterConnection
        printf "\r==> kubernetes distro:[%s] version:[%s] is now configured for user [%s] and ready for Mifos Gazelle deployment \n" \
                    "$k8s_distro" "$K8S_VERSION" "$k8s_user"
        print_end_message
    elif [[ "$mode" == "cleanall" ]]  ; then
        if [[ "$environment" == "local" ]]; then
            echo "Deleting local kubernetes cluster..."
            delete_k8s
            echo "Local Kubernetes deleted" 
        fi
        print_end_message_tear_down
    else
        showUsage
    fi
}




