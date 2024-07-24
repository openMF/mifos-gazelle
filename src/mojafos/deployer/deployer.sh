#!/usr/bin/env bash


function deleteResourcesInNamespsceMatchingPattern(){
  local pattern="$1"

    # Check if the pattern is provided
    if [ -z "$pattern" ]; then
        echo "Pattern not provided."
        exit 1
    fi

    # Get the list of namespaces and filter them based on the pattern
    namespaces=$(kubectl get namespaces -o=name | grep "$pattern")

    # Loop through the filtered namespaces and delete resources in each one
    while IFS= read -r namespace; do
        namespace=$(echo "$namespace" | cut -d'/' -f2)
        kubectl delete all --all -n "$namespace"
        if [ $? -eq 0 ]; then
            echo "All resources in namespace $namespace deleted successfully."
        else
            echo "Error deleting resources in namespace $namespace."
        fi
    done <<< "$namespaces"
}

function deployHelmChartFromDir() {
  # Check if Helm is installed
  if ! command -v helm &>/dev/null; then
    echo "Helm is not installed. Please install Helm first."
    exit 1
  fi

  # Check if the chart directory exists
  local chart_dir="$1"
  local namespace="$2"
  local release_name="$3"
  if [ ! -d "$chart_dir" ]; then
    echo "Chart directory '$chart_dir' does not exist."
    exit 1
  fi

  # Check if a values file has been provided
  values_file="$4"

  # Enter the chart directory
  cd "$chart_dir" || exit 1

  # Run helm dependency update to fetch dependencies
  echo "Updating Helm chart dependencies..."
  helm dependency update >> /dev/null 2>&1
  echo -e "==> Helm chart updated"

  # Run helm dependency build
  echo "Building Helm chart dependencies..."
  helm dependency build . >> /dev/null 2>&1
  echo -e "==> Helm chart dependencies built"

  # Determine whether to install or upgrade the chart also check whether to apply a values file
  if [ -n "$values_file" ]; then
    if helm list -n "$namespace" | grep -q "$release_name"; then
      echo "Upgrading Helm chart..."
      helm upgrade --install "$release_name" . -n "$namespace" -f "$values_file"
      echo -e "==> Helm chart upgraded"
    else
      echo "Installing Helm chart..."
      helm install "$release_name" . -n "$namespace" -f "$values_file"
      echo -e "==> Helm chart installed"
    fi
  else
    if helm list -n "$namespace" | grep -q "$release_name"; then
      echo "Upgrading Helm chart..."
      helm upgrade --install "$release_name" . -n "$namespace"
      echo -e "==> Helm chart upgraded"
    else
      echo "Installing Helm chart..."
      helm install "$release_name" . -n "$namespace"
      echo -e "==> Helm chart installed"
    fi
  fi

  # Use kubectl to get the resource count in the specified namespace
  resource_count=$(kubectl get pods -n "$namespace" --ignore-not-found=true 2>/dev/null | grep -v "No resources found" | wc -l)

  # Check if the deployment was successful
  if [ $resource_count -gt 0 ]; then
    echo "Helm chart deployed successfully."
  else
    echo -e "${RED}Helm chart deployment failed.${RESET}"
    cleanUp
  fi

  # Exit the chart directory
  cd - || exit 1

}

function preparePaymentHubChart(){
  # Clone the repositories
  cloneRepo "$PH_EE_ENV_LABS_REPO_BRANCH" "$PH_EE_ENV_LABS_REPO_LINK" "$APPS_DIR" "$PH_EE_ENV_LABS_REPO_DIR"
  cloneRepo "$PH_EE_ENV_TEMPLATE_REPO_BRANCH" "$PH_EE_ENV_TEMPLATE_REPO_LINK" "$APPS_DIR" "$PH_EE_ENV_TEMPLATE_REPO_DIR"

  # Update helm dependencies and repo index for ph-ee-engine
  phEEenginePath="$APPS_DIR$PH_EE_ENV_TEMPLATE_REPO_DIR/helm/ph-ee-engine"
  pushd "$phEEenginePath"
  helm dep update 
  helm repo index .
  popd

  # Update helm dependencies and repo index for g2p-sandbox in ph-ee-env-template
  g2pSandboxChartPath="$APPS_DIR$PH_EE_ENV_TEMPLATE_REPO_DIR/helm/g2p-sandbox"
  awk '/repository:/ && c == 0 {sub(/repository: .*/, "repository: file://../ph-ee-engine"); c++} {print}' "$g2pSandboxChartPath/Chart.yaml" > "$g2pSandboxChartPath/Chart.yaml.tmp" && mv "$g2pSandboxChartPath/Chart.yaml.tmp" "$g2pSandboxChartPath/Chart.yaml"
  pushd "$g2pSandboxChartPath"
  helm dep update 
  helm repo index .
  popd

  # Update helm dependencies and repo index for g2p-sandbox-fynarfin-SIT in ph-ee-env-labs
  g2pSandboxFinalChartPath="$APPS_DIR$PH_EE_ENV_LABS_REPO_DIR/helm/g2p-sandbox-fynarfin-SIT"
  awk '/repository:/ && c == 0 {sub(/repository: .*/, "repository: file://../../../'$PH_EE_ENV_TEMPLATE_REPO_DIR'/helm/g2p-sandbox"); c++} {print}' "$g2pSandboxFinalChartPath/Chart.yaml" > "$g2pSandboxFinalChartPath/Chart.yaml.tmp" && mv "$g2pSandboxFinalChartPath/Chart.yaml.tmp" "$g2pSandboxFinalChartPath/Chart.yaml"
  pushd "$g2pSandboxFinalChartPath"
  helm dep update 
  helm repo index .
  popd
}

function deployPhHelmChartFromDir(){
  # Parameters
  local namespace="$1"
  local chartDir="$2"      # Directory containing the Helm chart
  local valuesFile="$3"    # Values file for the Helm chart

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

  # Install Prometheus Operator as a dependency
  LATEST=$(curl -s https://api.github.com/repos/prometheus-operator/prometheus-operator/releases/latest | jq -cr .tag_name)
  su - "$k8s_user" -c "curl -sL https://github.com/prometheus-operator/prometheus-operator/releases/download/${LATEST}/bundle.yaml | kubectl create -f -"

  # Install the Helm chart from the local directory
  if [ -z "$valuesFile" ]; then
    su - "$k8s_user" -c "helm install $PH_RELEASE_NAME $chartDir -n $namespace"
  else
    su - "$k8s_user" -c "helm install $PH_RELEASE_NAME $chartDir -n $namespace -f $valuesFile"
  fi

  # Check deployment status
  resource_count=$(kubectl get pods -n "$namespace" --ignore-not-found=true 2>/dev/null | grep -v "No resources found" | wc -l)

  if [ "$resource_count" -gt 0 ]; then
    echo "Helm chart deployed successfully."
  else
    echo -e "${RED}Helm chart deployment failed.${RESET}"
    cleanUp
  fi
}

function createNamespace () {
  local namespace=$1
  printf "==> Creating namespace $namespace \n"
  # Check if the namespace already exists
  if kubectl get namespace "$namespace" >> /dev/null 2>&1; then
      echo -e "${RED}Namespace $namespace already exists.${RESET}"
      exit 1
  fi

  # Create the namespace
  kubectl create namespace "$namespace"
  if [ $? -eq 0 ]; then
      echo -e "==> Namespace $namespace created successfully."
  else
      echo "Failed to create namespace $namespace."
  fi
}

function deployInfrastructure () {
  printf "==> Deploying infrastructure \n"
  createNamespace $INFRA_NAMESPACE
  if [ "$debug" = true ]; then
    deployHelmChartFromDir "./src/mojafos/deployer/helm/infra" "$INFRA_NAMESPACE" "$INFRA_RELEASE_NAME"
  else 
    deployHelmChartFromDir "./src/mojafos/deployer/helm/infra" "$INFRA_NAMESPACE" "$INFRA_RELEASE_NAME" >> /dev/null 2>&1
  fi
  echo -e "\n${GREEN}============================"
  echo -e "Infrastructure Deployed"
  echo -e "============================${RESET}\n"
}

function cloneRepo() {
  if [ "$#" -ne 4 ]; then
      echo "Usage: cloneRepo <branch> <repo_link> <target_directory> <cloned_directory_name>"
      return 1
  fi

  # Store the current working directory
  original_dir="$(pwd)"

  branch="$1"
  repo_link="$2"
  target_directory="$3"
  cloned_directory_name="$4"

  # Check if the target directory exists; if not, create it.
  if [ ! -d "$target_directory" ]; then
      mkdir -p "$target_directory"
  fi

  # Change to the target directory.
  cd "$target_directory" || return 1

  # Clone the repository with the specified branch into the specified directory.
  if [ -d "$cloned_directory_name" ]; then
    echo -e "${YELLOW}$cloned_directory_name Repo exists deleting and re-cloning ${RESET}"
    rm -rf "$cloned_directory_name"
    git clone -b "$branch" "$repo_link" "$cloned_directory_name" >> /dev/null 2>&1
  else
    git clone -b "$branch" "$repo_link" "$cloned_directory_name" >> /dev/null 2>&1
  fi

  if [ $? -eq 0 ]; then
      echo "==> Repository cloned successfully."
  else
      echo "Failed to clone the repository."
  fi

  # Change back to the original directory
  cd "$original_dir" || return 1
}

function applyKubeManifests() {
    if [ "$#" -ne 2 ]; then
        echo "Usage: applyKubeManifests <directory> <namespace>"
        return 1
    fi

    local directory="$1"
    local namespace="$2"

    # Check if the directory exists.
    if [ ! -d "$directory" ]; then
        echo "Directory '$directory' not found."
        return 1
    fi

    # Use 'kubectl apply' to apply manifests in the specified directory.
    kubectl apply -f "$directory" -n "$namespace" >> /dev/null 2>&1

    if [ $? -eq 0 ]; then
        echo -e "==>Kubernetes manifests applied successfully."
    else
        echo -e "${RED}Failed to apply Kubernetes manifests.${RESET}"
    fi
}

function runFailedSQLStatements(){
  echo "Fxing Operations App MySQL Race condition"
  operationsDeplName=$(kubectl get deploy --no-headers -o custom-columns=":metadata.name" -n $PH_NAMESPACE | grep operations-app)
  kubectl exec -it mysql-0 -n infra -- mysql -h mysql -uroot -pethieTieCh8ahv < src/mojafos/deployer/setup.sql

  if [ $? -eq 0 ];then
    echo "SQL File execution successful"
  else 
    echo "SQL File execution failed"
    exit 1
  fi

  echo "Restarting Deployment for Operations App"
  kubectl rollout restart deploy/$operationsDeplName -n $PH_NAMESPACE

  if [ $? -eq 0 ];then
    echo "Deployment Restart successful"
  else 
    echo "Deployment Restart failed"
    exit 1
  fi
}

function addKubeConfig(){
  K8sConfigDir="$k8s_user_home/.kube"

  if [ ! -d "$K8sConfigDir" ]; then
      su - $k8s_user -c "mkdir -p $K8sConfigDir"
      echo "K8sConfigDir created: $K8sConfigDir"
  else
      echo "K8sConfigDir already exists: $K8sConfigDir"
  fi
  su - $k8s_user -c "cp $k8s_user_home/k3s.yaml $K8sConfigDir/config"
}

#Function to run kong migrations in Kong init container 
function runKongMigrations(){
  echo "Fixing Kong Migrations"
  #StoreKongPods
  kongPods=$(kubectl get pods --no-headers -o custom-columns=":metadata.name" -n $PH_NAMESPACE | grep moja-ph-kong)
  dBcontainerName="wait-for-db"
  for pod in $kongPods; 
  do 
    podName=$(kubectl get pod $pod --no-headers -o custom-columns=":metadata.labels.app" -n $PH_NAMESPACE)
    if [[ "$podName" == "moja-ph-kong" ]]; then 
        initContainerStatus=$(kubectl get pod $pod  --no-headers -o custom-columns=":status.initContainerStatuses[0].ready" -n $PH_NAMESPACE)
      while [[ "$initContainerStatus" != "true" ]]; do
        printf "\rReady State: $initContainerStatus Waiting for status to become true ..."
        initContainerStatus=$(kubectl get pod $pod  --no-headers -o custom-columns=":status.initContainerStatuses[0].ready" -n $PH_NAMESPACE)
        sleep 5
      done
      echo "Status is now true"
      while  kubectl get pod "$podName" -o jsonpath="{:status.initContainersStatuses[1].name}" | grep -q "$dBcontainerName" ; do
        printf "\r Waiting for Init DB container to be created ..."
        sleep 5
      done

      echo && echo $pod
      statusCode=1
      while [ $statusCode -eq 1 ]; do
        printf "\rRunning Migrations ..."
        kubectl exec $pod -c $dBcontainerName -n $PH_NAMESPACE -- kong migrations bootstrap >> /dev/null 2>&1
        statusCode=$?
        if [ $statusCode -eq 0 ]; then
          echo "\nKong Migrations Successful"
        fi
      done
    else
      continue
    fi
  done
}

function postPaymenthubDeploymentScript(){
  #Run migrations in Kong Pod
  runKongMigrations
  # Run failed MySQL statements.
  runFailedSQLStatements
}

function deployMojaloop() {
  echo "Deploying Mojaloop vNext application manifests"
  createNamespace "$MOJALOOP_NAMESPACE"
  echo
  cloneRepo "$MOJALOOPBRANCH" "$MOJALOOP_REPO_LINK" "$APPS_DIR" "$MOJALOOPREPO_DIR"
  echo
  # renameOffToYaml "${MOJALOOP_LAYER_DIRS[0]}"
  echo
  configureMojaloop

  for index in "${!MOJALOOP_LAYER_DIRS[@]}"; do
    folder="${MOJALOOP_LAYER_DIRS[index]}"
    echo "Deploying files in $folder"
    applyKubeManifests "$folder" "$MOJALOOP_NAMESPACE"
    if [ "$index" -eq 0 ]; then
      echo -e "${BLUE}Waiting for Mojaloop cross cutting concerns to come up${RESET}"
      sleep 10
      echo -e "Proceeding ..."
    fi
  done

  echo -e "\n${GREEN}============================"
  echo -e "Mojaloop Deployed"
  echo -e "============================${RESET}\n"
}

function deployPaymentHubEE() {
  echo "Deploying PaymentHub EE"
  createNamespace "$PH_NAMESPACE"
  cloneRepo "$PHBRANCH" "$PH_REPO_LINK" "$APPS_DIR" "$PHREPO_DIR"
  configurePH "$APPS_DIR$PHREPO_DIR/helm"
  
  for((i=1; i<=2; i++))
  do
    if [ "$debug" = true ]; then
      deployHelmChartFromDir "$APPS_DIR$PHREPO_DIR/helm/g2p-sandbox-fynarfin-SIT" "$PH_NAMESPACE" "$PH_RELEASE_NAME" "$PH_VALUES_FILE"
    else 
      deployHelmChartFromDir "$APPS_DIR$PHREPO_DIR/helm/g2p-sandbox-fynarfin-SIT" "$PH_NAMESPACE" "$PH_RELEASE_NAME" "$PH_VALUES_FILE" >> /dev/null 2>&1
    fi
  done 

  echo -e "\n${YELLOW}Fixing Paymenthub post deployment issues(might take a while)...${RESET}"
  postPaymenthubDeploymentScript >> /dev/null 2>&1

  echo -e "\n${GREEN}============================"
  echo -e "Paymenthub Deployed"
  echo -e "============================${RESET}\n"
}

function deployPH(){
  echo "Deploying PaymentHub EE"
  createNamespace "$PH_NAMESPACE"
  cloneRepo "$PHBRANCH" "$PH_REPO_LINK" "$APPS_DIR" "$PHREPO_DIR"
  configurePH "$APPS_DIR$PHREPO_DIR/helm"
  # deployPhHelmChartFromRepo "$PH_NAMESPACE"
  preparePaymentHubChart
  deployPhHelmChartFromDir "$PH_NAMESPACE" "$g2pSandboxFinalChartPath" "$PH_VALUES_FILE"

  echo -e "\n${GREEN}============================"
  echo -e "Paymenthub Deployed"
  echo -e "============================${RESET}\n"
}

function deployFineract() {
  echo -e "${BLUE}Deploying Fineract${RESET}"

  cloneRepo "$FIN_BRANCH" "$FIN_REPO_LINK" "$APPS_DIR" "$FIN_REPO_DIR"
  configureFineract

  num_instances=$1

  if [[ -z "$num_instances" ]];then
    num_instances=2
  fi

  echo -e "Deploying $num_instances instances of fineract"

  # Check if the input is a valid integer
  for ((i=1; i<=num_instances; i++))
  do
    sed -i "s/\([0-9]-\)\?fynams.sandbox.fynarfin.io/$i-fynams.sandbox.fynarfin.io/" "$FIN_VALUES_FILE"
    sed -i "s/\([0-9]-\)\?communityapp.sandbox.fynarfin.io/$i-communityapp.sandbox.fynarfin.io/" "$FIN_VALUES_FILE"
    sed -i "s/\([0-9]-\)\?webapp.sandbox.fynarfin.io/$i-webapp.sandbox.fynarfin.io/" "$FIN_VALUES_FILE"
    createNamespace "$FIN_NAMESPACE-$i"
    if [ "$debug" = true ]; then
      deployHelmChartFromDir "$APPS_DIR$FIN_REPO_DIR/helm/fineract" "$FIN_NAMESPACE-$i" "$FIN_RELEASE_NAME-$i" "$FIN_VALUES_FILE"
    else 
      deployHelmChartFromDir "$APPS_DIR$FIN_REPO_DIR/helm/fineract" "$FIN_NAMESPACE-$i" "$FIN_RELEASE_NAME-$i" "$FIN_VALUES_FILE" >> /dev/null 2>&1
    fi

      echo -e "\n${GREEN}============================"
      echo -e "fineract-$i Deployed"
      echo -e "============================${RESET}\n"
  done
}

function test_ml {
  echo "TODO" #TODO Write function to test apps
}

function test_ph {
  echo "TODO"
}

function test_fin {
  local instance_name=$1
}

function printEndMessage {
  echo -e "==========================="
  echo -e "Thank you for using Mojafos"
  echo -e "===========================\n\n"
  echo -e "CHECK DEPLOYMENTS USING kubectl"
  echo -e "kubectl get pods -n mojaloop #For testing mojaloop"
  echo -e "kubectl get pods -n paymenthub #For testing paymenthub"
  echo -e "kubectl get pods -n fineract-x #For testing fineract. x is a number of a fineract instance\n\n"
  echo -e "Copyright © 2023 The Mifos Initiative"
}

function deployApps {
  fin_num_instances="$1"
  appsToDeploy="$2"

  if [ -z "$appsToDeploy" ]; then
    echo -e "${BLUE}Deploying all apps ...${RESET}"
    deployInfrastructure
    deployMojaloop
    deployPH
    deployFineract "$fin_num_instances"
  elif [[ "$appsToDeploy" == "all" ]]; then
    echo -e "${BLUE}Deploying all apps ...${RESET}"
    deployInfrastructure
    deployMojaloop
    deployPH
    deployFineract "$fin_num_instances"
  elif [[ "$appsToDeploy" == "moja" ]];then
    deployInfrastructure
    deployMojaloop
  elif [[ "$appsToDeploy" == "fin" ]]; then 
    deployInfrastructure
    deployFineract "$fin_num_instances"
  elif [[ "$appsToDeploy" == "ph" ]]; then
    deployPH
  else 
    echo -e "${RED}Invalid option ${RESET}"
    echo "Defaulting to all... "
    deployInfrastructure
    deployMojaloop
    deployPH
    deployFineract "$fin_num_instances"
  fi
  addKubeConfig >> /dev/null 2>&1
  printEndMessage
}
