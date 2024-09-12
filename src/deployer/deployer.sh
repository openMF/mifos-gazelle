#!/usr/bin/env bash

# Function to check and handle command execution errors
check_command_execution() {
  if [ $? -ne 0 ]; then
    echo "Error: $1 failed"
    exit 1
  fi
}

function isPodRunning() {
    local podname="$1"
    local namespace="$2"

    # Get the pod status
    local pod_status
    pod_status=$(kubectl get pod "$podname" -n "$namespace" -o jsonpath='{.status.phase}')

    # Check if the pod is running
    if [[ "$pod_status" == "Running" ]]; then
        echo "true"
    else
        echo "false"
    fi
}

function isDeployed {
    local app_name="$1"
    if [[ "$app_name" == "infra" ]]; then
      # Check if the namespace exists
      if ! kubectl get namespace "$INFRA_NAMESPACE" > /dev/null 2>&1; then
          echo "false"
          return
      fi
      # namespace exists so Check if the infra Helm chart is deployed and running in the $INFRA_NAMESPACE
      helm_status=$(helm status infra -n "$INFRA_NAMESPACE" 2>&1)
      #echo "helm status is $helm_status"
      if echo "$helm_status" | awk '/^STATUS:/ {if ($2 == "deployed") exit 0; else exit 1}'; then
          echo "true"
      else
          echo "false"
      fi
    elif [[ "$app_name" == "phee" ]]; then 
      # Check if the namespace exists
      if ! kubectl get namespace "$PH_NAMESPACE" > /dev/null 2>&1; then
          echo "false"
          return
      fi
      helm_status=$(helm status phee -n "$PHEE_NAMESPACE" 2>&1)
      if echo "$helm_status" | awk '/^STATUS:/ {if ($2 == "deployed") exit 0; else exit 1}'; then
          echo "true"
      else
          echo "false"
      fi
    elif [[ "$app_name" == "vnext" ]]; then 
      # Check if the namespace exists
      if ! kubectl get namespace "$VNEXT_NAMESPACE" > /dev/null 2>&1; then
          echo "false"
          return
      fi
      # assume if greenbank-backend-0 is running ok then vnext is installed 
      local podname="greenbank-backend-0"
      if [[ "$(isPodRunning "$podname" "$VNEXT_NAMESPACE")" == "true" ]]; then
        echo "true"
      else
        echo "false"
      fi
    elif [[ "$app_name" == "mifosx" ]]; then
      # MifosX installs so quickly we just redeploy each time 
      echo "false"
    fi
}

function manageSecrets {
    local action="$1"
    local namespace="$2"
    local certdir="$3" # location of the .p12 and .pem files 
    local password="XVYgwycNuEygEEEI0hQF"  #see 

    # Create a temporary directory to store the generated files
    temp_dir=$(mktemp -d)

    if [[ "$action" == "create" ]]; then
      echo "creating elastic and kibana secrets" 
      # Convert the certificates and store them in the temporary directory
      openssl pkcs12 -nodes -passin pass:'' -in $certdir/elastic-certificates.p12 -out "$temp_dir/elastic-certificate.pem"  >> /dev/null 2>&1
      openssl x509 -outform der -in "$certdir/elastic-certificate.pem" -out "$temp_dir/elastic-certificate.crt"  >> /dev/null 2>&1

      # Create the ES secrets in the specified namespace
      kubectl create secret generic elastic-certificates --namespace="$namespace" --from-file="$certdir/elastic-certificates.p12" >> /dev/null 2>&1
      kubectl create secret generic elastic-certificate-pem --namespace="$namespace" --from-file="$temp_dir/elastic-certificate.pem" >> /dev/null 2>&1
      kubectl create secret generic elastic-certificate-crt --namespace="$namespace" --from-file="$temp_dir/elastic-certificate.crt" >> /dev/null 2>&1
      kubectl create secret generic elastic-credentials --namespace="$namespace" --from-literal=password="$password" --from-literal=username=elastic >> /dev/null 2>&1

      local encryptionkey=MMFI5EFpJnib4MDDbRPuJ1UNIRiHuMud_r_EfBNprx7qVRlO7R 
      kubectl create secret generic kibana --namespace="$namespace" --from-literal=encryptionkey=$encryptionkey >> /dev/null 2>&1

    elif [[ "$action" == "delete" ]]; then
      echo "Deleting elastic and kibana secrets" 
      # Delete the secrets from the specified namespace
      kubectl delete secret elastic-certificates --namespace="$namespace" >> /dev/null 2>&1
      kubectl delete secret elastic-certificate-pem --namespace="$namespace" >> /dev/null 2>&1
      kubectl delete secret elastic-certificate-crt --namespace="$namespace" >> /dev/null 2>&1
      kubectl delete secret elastic-credentials --namespace="$namespace" >> /dev/null 2>&1
      kubectl delete secret  kibana --namespace="$namespace" >> /dev/null 2>&1
    else
      echo "Invalid action. Use 'create' or 'delete'."
      rm -rf "$temp_dir"  # Clean up the temporary directory
      return 1
    fi

    # Clean up the temporary directory
    rm -rf "$temp_dir"
}

function cloneRepo() {
  if [ "$#" -ne 4 ]; then
      echo "Usage: cloneRepo <branch> <repo_link> <target_directory> <cloned_directory_name>"
      return 1
  fi
  local branch="$1"
  local repo_link="$2"
  local target_directory="$3"
  local cloned_directory_name="$4"
  local repo_path="$target_directory/$cloned_directory_name"

  # Check if the target directory exists; if not, create it.
  if [ ! -d "$target_directory" ]; then
      mkdir -p "$target_directory"
  fi
  chown -R "$k8s_user" "$target_directory"

  # Check if the repository already exists.
  if [ -d "$repo_path" ]; then
    #echo "Repository $repo_path already exists. Checking for updates..."

    cd "$repo_path" || exit

    # Fetch the latest changes.
    su - "$k8s_user" -c "git fetch origin $branch" >> /dev/null 2>&1

    # Compare local branch with the remote branch.
    LOCAL=$(git rev-parse @)
    REMOTE=$(git rev-parse @{u})

    if [ "$LOCAL" != "$REMOTE" ]; then
        echo -e "${YELLOW}Repository $repo_path has updates. Recloning...${RESET}"
        rm -rf "$repo_path"
        su - "$k8s_user" -c "git clone -b $branch $repo_link $repo_path" >> /dev/null 2>&1
    else
        echo "    Repository $repo_path is up-to-date. No need to reclone."
    fi
  else
    # Clone the repository if it doesn't exist locally.
    su - "$k8s_user" -c "git clone -b $branch $repo_link $repo_path" >> /dev/null 2>&1
    if [ $? -eq 0 ]; then
      echo "    Repository $repo_path cloned successfully."
    else
        echo "** Error Failed to clone the repository."
    fi
  fi
}

# function packageHelmCharts {
#   current_dir=`pwd`
#   cd $HOME/helm
#   if [[ "$NEED_TO_REPACKAGE" == "true" ]]; then 
#     tstart=$(date +%s)
#     printf "==> running repackage of the all the Mojaloop helm charts to incorporate local configuration "
#     status=`./package.sh >> $LOGFILE 2>>$ERRFILE`
#     tstop=$(date +%s)
#     telapsed=$(timer $tstart $tstop)
#     timer_array[repackage_ml]=$telapsed
#     if [[ "$status" -eq 0  ]]; then 
#       printf " [ ok ] \n"
#       NEED_TO_REPACKAGE="false"
#     else
#       printf " [ failed ] \n"
#       printf "** please try running $HOME/helm/package.sh manually to determine the problem **  \n" 
#       cd $current_dir
#       exit 1
#     fi  
#   fi 
 
#   cd $current_dir
# }

function deleteResourcesInNamespaceMatchingPattern() {
    local pattern="$1"  
    # Check if the pattern is provided
    if [ -z "$pattern" ]; then
        echo "Pattern not provided."
        return 1
    fi
    
    # Get namespaces matching the pattern
    local namespaces=$(kubectl get namespaces -o name | grep "$pattern")
    if [ -z "$namespaces" ]; then
        echo "No namespaces found matching pattern: $pattern"
        return 0
    fi
    
    echo "$namespaces" | while read -r namespace; do
        namespace=$(echo "$namespace" | cut -d'/' -f2)
        if [[ $namespace == "default" ]]; then
          local deployment_name="prometheus-operator"
          deployment_available=$(kubectl get deployment "$deployment_name" -n "default" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')
          if [[ "$deployment_available" == "True" ]]; then
            printf  "Deleting Prometheus Operator resources in default namespace"
            LATEST=$(curl -s https://api.github.com/repos/prometheus-operator/prometheus-operator/releases/latest | jq -cr .tag_name)
            su - "$k8s_user" -c "curl -sL https://github.com/prometheus-operator/prometheus-operator/releases/download/${LATEST}/bundle.yaml | kubectl -n default delete -f -" >/dev/null 2>&1
            if [ $? -eq 0 ]; then
                echo " [ok] "
            else
                echo "Warning: there was an issue uninstalling  Prometheus Operator resources in default namespace."
                echo "         you can ignore this if Prometheus was not expected to be already running."
            fi
          fi
        else
            printf "    Deleting all resources in namespace $namespace "
            kubectl delete all --all -n "$namespace" >> /dev/null 2>&1
            kubectl delete ns "$namespace" >> /dev/null 2>&1
            if [ $? -eq 0 ]; then
                echo " [ok] "
            else
                echo "Error deleting resources in namespace $namespace."
            fi
        fi
    done
}

function deployHelmChartFromDir() {
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

  # Run helm dependency update to fetch dependencies
  # echo "Updating Helm chart dependencies..."
  # su - $k8s_user -c "helm dependency update" >> /dev/null 2>&1
  # echo -e "==> Helm chart updated"

  # # Run helm dependency build
  # echo "Building Helm chart dependencies..."
  # su - $k8s_user -c "helm dependency build ."  >> /dev/null 2>&1
  # echo -e "==> Helm chart dependencies built"

  # TODO Determine whether to install or upgrade the chart also check whether to apply a values file
  #su - $k8s_user -c "helm list -n $namespace"
  if [ -n "$values_file" ]; then
      echo "Installing Helm chart using values: $values_file..."
      su - $k8s_user -c "helm install $release_name $chart_dir -n $namespace -f $values_file"
  else
      echo "Installing Helm chart using default values file ..."
      su - $k8s_user -c "helm install $release_name $chart_dir -n $namespace "
  fi

  # tomd todo : is the chart really deployed ok, need a test
  # Use kubectl to get the resource count in the specified namespace
  #resource_count=$(kubectl get pods -n "$namespace" --ignore-not-found=true 2>/dev/null | grep -v "No resources found" | wc -l)
  resource_count=$(sudo -u $k8s_user kubectl get pods -n "$namespace" --ignore-not-found=true 2>/dev/null | grep -v "No resources found" | wc -l)
  # Check if the deployment was successful
  if [ $resource_count -gt 0 ]; then
    echo "Helm chart deployed successfully."
  else
    echo -e "${RED}Helm chart deployment failed.${RESET}"
    cleanUp
  fi

}

function preparePaymentHubChart(){
  # Clone the repositories
  # 
  cloneRepo "$PHBRANCH" "$PH_REPO_LINK" "$APPS_DIR" "$PHREPO_DIR"  # needed for kibana and elastic secrets only 
  cloneRepo "$PH_EE_ENV_TEMPLATE_REPO_BRANCH" "$PH_EE_ENV_TEMPLATE_REPO_LINK" "$APPS_DIR" "$PH_EE_ENV_TEMPLATE_REPO_DIR"

  # Update helm dependencies and repo index for ph-ee-engine
  echo "    udating dependencies ph-ee-engine chart "
  phEEenginePath="$APPS_DIR/$PH_EE_ENV_TEMPLATE_REPO_DIR/helm/ph-ee-engine"
  su - $k8s_user -c "cd $phEEenginePath;  helm dep update" >> /dev/null 2>&1 
  su - $k8s_user -c "cd $phEEenginePath;  helm repo index ."

  # Update helm dependencies and repo index for gazelle i.e. parent chart of ph-ee-engine 
  echo "    updating dependencies gazelle chart "
  gazelleChartPath="$APPS_DIR/$PH_EE_ENV_TEMPLATE_REPO_DIR/helm/gazelle"
  su - $k8s_user -c "cd $gazelleChartPath ; helm dep update >> /dev/null 2>&1 " 
  su - $k8s_user -c "cd $gazelleChartPath ; helm repo index ."
}

function checkPHEEDependencies() {
  printf "    Installing Prometheus " 
  # Install Prometheus Operator if needed as it is a PHEE dependency
  local deployment_name="prometheus-operator"
  deployment_available=$(kubectl get deployment "$deployment_name" -n "default" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' > /dev/null 2>&1)
  if [[ "$deployment_available" == "True" ]]; then
    echo -e "${RED} prometheus already installed -skipping install. ${RESET}" 
    return 0
  fi 
  LATEST=$(curl -s https://api.github.com/repos/prometheus-operator/prometheus-operator/releases/latest | jq -cr .tag_name)
  su - $k8s_user -c "curl -sL https://github.com/prometheus-operator/prometheus-operator/releases/download/${LATEST}/bundle.yaml | kubectl create -f - " >/dev/null 2>&1
  if [ $? -eq 0 ]; then
      echo " [ok] "
  else
      echo "   Failed to install prometheus"
      exit 1 
  fi
}

function deployPhHelmChartFromDir(){
  # Parameters
  local namespace="$1"
  local chartDir="$2"      # Directory containing the Helm chart
  local valuesFile="$3"    # Values file for the Helm chart

  # Install the Helm chart from the local directory
  if [ -z "$valuesFile" ]; then
    echo "TDDEBUG NO values file > $k8s_user -c helm install $PH_RELEASE_NAME $chartDir -n $namespace"
    su - "$k8s_user" -c "helm install $PH_RELEASE_NAME $chartDir -n $namespace" >> /dev/null 2>&1
  else
    echo "TDDEBUG using values file > $k8s_user -c helm install $PH_RELEASE_NAME $chartDir -n $namespace -f $valuesFile "
    su - "$k8s_user" -c "helm install $PH_RELEASE_NAME $chartDir -n $namespace -f $valuesFile "  >> /dev/null 2>&1
  fi

  # Check deployment status
  # TODO: should strengthen this check for deployment success 
  resource_count=$(kubectl get pods -n "$namespace" --ignore-not-found=true 2>/dev/null | grep -v "No resources found" | wc -l)
  if [ "$resource_count" -gt 0 ]; then
    echo "Helm chart deployed successfully."
  else
    echo -e "${RED}Helm chart deployment failed.${RESET}"
    cleanUp
  fi
}

function deployPH(){
  if [[ "$(isDeployed "phee" )" == "true" ]]; then
    echo "it is already deployed" 
    if [[ "$redeploy" == "false" ]]; then
      echo "$PH_RELEASE_NAME is already deployed. Skipping deployment."
      return
    else # need to delete prior to redeploy 
      deleteResourcesInNamespaceMatchingPattern "$PH_NAMESPACE"
      deleteResourcesInNamespaceMatchingPattern "default"  #just removes prometheus at the moment
      manageSecrets delete "$INFRA_NAMESPACE" "$APPS_DIR/$PHREPO_DIR/helm/es-secret"
    fi
  fi 
  echo "Deploying PaymentHub EE"
  createNamespace "$PH_NAMESPACE"
  checkPHEEDependencies
  preparePaymentHubChart
  #configurePH "$APPS_DIR$PHREPO_DIR/helm"
  manageSecrets create "$PH_NAMESPACE" "$APPS_DIR/$PHREPO_DIR/helm/es-secret"
  manageSecrets create "$INFRA_NAMESPACE" "$APPS_DIR/$PHREPO_DIR/helm/es-secret"

  #deployPhHelmChartFromDir "$PH_NAMESPACE" "$g2pSandboxFinalChartPath" "$PH_VALUES_FILE"
  deployPhHelmChartFromDir "$PH_NAMESPACE" "$gazelleChartPath" "$PH_VALUES_FILE"
  echo -e "\n${GREEN}============================"
  echo -e "Paymenthub Deployed"
  echo -e "============================${RESET}\n"
}

function createNamespace () {
  local namespace=$1
  printf "    Creating namespace $namespace "
  # Check if the namespace already exists
  if kubectl get namespace "$namespace" >> /dev/null 2>&1; then
      echo -e "${RED}Namespace $namespace already exists -skipping creation.${RESET}"
      return 0
  fi

  # Create the namespace
  kubectl create namespace "$namespace" >> /dev/null 2>&1
  if [ $? -eq 0 ]; then
      echo -e " [ok] "
  else
      echo "Failed to create namespace $namespace."
  fi
}

function deployInfrastructure () {
  local redeploy="$1"
  printf "==> Deploying infrastructure \n"
  if [[ "$(isDeployed "infra")" == "true" ]]; then
    if [[ "$redeploy" == "false" ]]; then
      echo "    infrastructure is already deployed. Skipping deployment."
      return
    else # need to delete and deploy 
      deleteResourcesInNamespaceMatchingPattern "$INFRA_NAMESPACE"
    fi
  fi 
  createNamespace $INFRA_NAMESPACE

  # Update helm dependencies and repo index for infra chart 
  printf  "    udating dependencies for infra helm chart "
  su - $k8s_user -c "cd $INFRA_CHART_DIR;  helm dep update" >> /dev/null 2>&1 
  check_command_execution "Updating dependencies for infra chart"
  echo " [ok] "

  #su - $k8s_user -c "cd $INFRA_CHART_DIR;  helm repo index ."
  printf "    Deploying infra helm chart  "
  if [ "$debug" = true ]; then
    deployHelmChartFromDir "$RUN_DIR/src/deployer/helm/infra" "$INFRA_NAMESPACE" "$INFRA_RELEASE_NAME"
  else 
    deployHelmChartFromDir "$RUN_DIR/src/deployer/helm/infra" "$INFRA_NAMESPACE" "$INFRA_RELEASE_NAME" >> /dev/null 2>&1
  fi
  check_command_execution "Deploying infra helm chart"
  echo  " [ok] "
  echo -e "\n${GREEN}============================"
  echo -e "Infrastructure Deployed"
  echo -e "============================${RESET}\n"
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
    su - $k8s_user -c "kubectl apply -f $directory -n $namespace"  >> /dev/null 2>&1 
    if [ $? -eq 0 ]; then
        echo -e "    Kubernetes manifests applied successfully."
    else
        echo -e "${RED}Failed to apply Kubernetes manifests.${RESET}"
    fi
}

# function runFailedSQLStatements(){
#   echo "Fxing Operations App MySQL Race condition"
#   operationsDeplName=$(kubectl get deploy --no-headers -o custom-columns=":metadata.name" -n $PH_NAMESPACE | grep operations-app)
#   kubectl exec -it mysql-0 -n infra -- mysql -h mysql -uroot -pethieTieCh8ahv < src/deployer/setup.sql

#   if [ $? -eq 0 ];then
#     echo "SQL File execution successful"
#   else 
#     echo "SQL File execution failed"
#     exit 1
#   fi

#   echo "Restarting Deployment for Operations App"
#   kubectl rollout restart deploy/$operationsDeplName -n $PH_NAMESPACE

#   if [ $? -eq 0 ];then
#     echo "Deployment Restart successful"
#   else 
#     echo "Deployment Restart failed"
#     exit 1
#   fi
# }

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

function deployvNext() {
  echo "==> Deploying Mojaloop vNext application "
  if [[ "$(isDeployed "vnext" )" == "true" ]]; then
    if [[ "$redeploy" == "false" ]]; then
      echo "    vNext application is already deployed. Skipping deployment."
      return
      # else # need to delete prior to redeploy 
      #   deleteResourcesInNamespaceMatchingPattern "$VNEXT_NAMESPACE"
    fi
  fi 
  createNamespace "$VNEXT_NAMESPACE"
  cloneRepo "$VNEXTBRANCH" "$VNEXT_REPO_LINK" "$APPS_DIR" "$VNEXTREPO_DIR"
  configurevNext

  for index in "${!VNEXT_LAYER_DIRS[@]}"; do
    folder="${VNEXT_LAYER_DIRS[index]}"
    #echo "Deploying files in $folder"
    applyKubeManifests "$folder" "$VNEXT_NAMESPACE" >/dev/null 2>&1
    if [ "$index" -eq 0 ]; then
      echo -e "${BLUE}Waiting for vnext cross cutting concerns to come up${RESET}"
      sleep 10
      echo -e "Proceeding ..."
    fi
  done

  echo -e "\n${GREEN}============================"
  echo -e "vnext Deployed"
  echo -e "============================${RESET}\n"

}

function DeployMifosXfromYaml() {
  manifests_dir=$1
  num_instances="1"
  #num_instances=$2
  # TODO re implement multiple instances of MifosX deployment in different 
  #      namespaces. In the move away from the helm charts to the simple yamls 
  #      I (Tom D) temporarily hardcoded this just so we could get something working
  #      NOTE: MifosX i.e. web-app + fineract could easily be deoloyed from a 
  #            kubernetes operator and thus multiple deployments would be a simple
  #            part of that process. 
  echo "==> Deploying MifosX i.e. web-app and Fineract via application manifests"
  createNamespace "$MIFOSX_NAMESPACE-$num_instances"
  cloneRepo "$MIFOSX_BRANCH" "$MIFOSX_REPO_LINK" "$APPS_DIR" "$MIFOSX_REPO_DIR"

  #echo "Deploying files in $manifests_dir"
  applyKubeManifests "$manifests_dir" "$MIFOSX_NAMESPACE-$num_instances"

  echo -e "\n${GREEN}================================="
  echo -e "MifosX (fineract + web app) Deployed"
  echo -e "=====================================${RESET}\n"
} 

function test_vnext {
  echo "TODO" #TODO Write function to test apps
}

function test_phee {
  echo "TODO"
}

function test_mifosx {
  local instance_name=$1
}

function printEndMessage {
  echo -e "================================="
  echo -e "Thank you for using Mifos Gazelle"
  echo -e "=================================\n\n"
  echo -e "CHECK DEPLOYMENTS USING kubectl"
  echo -e "kubectl get pods -n vnext #For testing mojaloop vNext"
  echo -e "kubectl get pods -n paymenthub #For testing paymenthub"
  echo -e "kubectl get pods -n mifosx #For testing MifosX x is a number of a MifosX instances\n\n"
  echo -e "Copyright © 2023 The Mifos Initiative"
}

function deleteApps {
  mifosx_num_instances="$1"
  appsToDelete="$2"
  if [[ "$appsToDelete" == "all" ]]; then
    deleteResourcesInNamespaceMatchingPattern "$MIFOSX_NAMESPACE"
    deleteResourcesInNamespaceMatchingPattern "$VNEXT_NAMESPACE"
    deleteResourcesInNamespaceMatchingPattern "$PH_NAMESPACE"
    deleteResourcesInNamespaceMatchingPattern "$INFRA_NAMESPACE"
    deleteResourcesInNamespaceMatchingPattern "default"
  elif [[ "$appsToDelete" == "vnext" ]];then
    deleteResourcesInNamespaceMatchingPattern "$VNEXT_NAMESPACE"
  elif [[ "$appsToDelete" == "mifosx" ]]; then 
    deleteResourcesInNamespaceMatchingPattern "$MIFOSX_NAMESPACE"
  elif [[ "$appsToDelete" == "phee" ]]; then
    deleteResourcesInNamespaceMatchingPattern "$PH_NAMESPACE"
    echo "Handling Prometheus Operator resources in the default namespace"
    LATEST=$(curl -s https://api.github.com/repos/prometheus-operator/prometheus-operator/releases/latest | jq -cr .tag_name)
    su - "$k8s_user" -c "curl -sL https://github.com/prometheus-operator/prometheus-operator/releases/download/${LATEST}/bundle.yaml | kubectl -n default delete -f -" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "Warning: there was an issue uninstalling  Prometheus Operator resources in default namespace."
        echo "         you can ignore this if Prometheus was not expected to be already running."
    fi

  elif [[ "$appsToDelete" == "infra" ]]; then
    deleteResourcesInNamespaceMatchingPattern "$INFRA_NAMESPACE"
  else 
    echo -e "${RED}Invalid -a option ${RESET}"
    showUsage
    exit 
  fi  
}

function deployApps {
  mifosx_num_instances="$1"
  appsToDeploy="$2"
  redeploy="$3"

  if [[ "$appsToDeploy" == "all" ]]; then
    echo -e "${BLUE}Deploying all apps ...${RESET}"
    deployInfrastructure "$redeploy" 
    deployvNext
    deployPH
    DeployMifosXfromYaml "$MIFOSX_MANIFESTS_DIR"  "$mifosx_num_instances"
  elif [[ "$appsToDeploy" == "infra" ]];then
    deployInfrastructure
  elif [[ "$appsToDeploy" == "vnext" ]];then
    deployInfrastructure "false"
    deployvNext
  elif [[ "$appsToDeploy" == "mifosx" ]]; then 
    deployInfrastructure "false"
    DeployMifosXfromYaml "$MIFOSX_MANIFESTS_DIR"  "$MIFOSX_num_instances"
  elif [[ "$appsToDeploy" == "phee" ]]; then
    deployPH
  else 
    echo -e "${RED}Invalid option ${RESET}"
    showUsage
    exit 
  fi
  addKubeConfig >> /dev/null 2>&1
  printEndMessage
}
