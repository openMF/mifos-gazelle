#!/usr/bin/env bash
# deployer.sh -- the main Mifos Gazelle deployer script

# Function to check and handle command execution errors
check_command_execution() {
  local msg=$1
  if [ $? -ne 0 ]; then
    echo "Error: $1 failed"
    exit 1
  fi
}

# Debug function to check if a function exists
function function_exists() {
    declare -f "$1" > /dev/null
    return $?
}

function isPodRunning() {
    local podname="$1" namespace="$2"
    if [[ -z "$podname" || -z "$namespace" ]]; then
        return 1
    fi
    local pod_status
    pod_status=$(kubectl get pod "$podname" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null)
    [[ "$pod_status" == "Running" ]]
}

isDeployed() {
    local app_name="$1" namespace="$2" pod_name="$3" full_pod_name
    kubectl get namespace "$namespace" >/dev/null 2>&1 || { echo "false"; return; }
    full_pod_name=$(kubectl get pods -n "$namespace" --no-headers -o custom-columns=":metadata.name" | grep -i "$pod_name" | head -1)
    if [[ -z "$full_pod_name" ]]; then
        echo "false"
        return
    fi
    if isPodRunning "$full_pod_name" "$namespace"; then
        echo "true"
    else
        echo "false"
    fi
}

waitForPodReadyByPartialName() {
  local namespace="$1"
  local partial_podname="$2"
  local max_wait_seconds=300
  local sleep_interval=5
  local elapsed=0
  local podname

  while (( elapsed < max_wait_seconds )); do
    podname=$(kubectl get pods -n "$namespace" --no-headers -o custom-columns=":metadata.name" | grep -i "$partial_podname" | head -1)

    if [[ -n "$podname" ]]; then
      # Check if pod is Ready (Ready condition == True)
      local ready_status
      ready_status=$(kubectl get pod "$podname" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')

      if [[ "$ready_status" == "True" ]]; then
        echo "$podname"
        return 0
      fi
    fi

    echo "⏳ Waiting for pod matching '$partial_podname' to be Ready in namespace '$namespace'... ($elapsed seconds elapsed)"
    sleep "$sleep_interval"
    ((elapsed+=sleep_interval))
  done

  echo -e "${RED}    Error: Pod matching '$partial_podname' did not become Ready within 5 minutes.${RESET}" >&2
  return 1
}

deployBPMS() {
  local host="https://zeebeops.mifos.gazelle.test/zeebe/upload"
  local DEBUG=false
  local successful_uploads=0
  local BPMNS_DIR="$BASE_DIR/orchestration/feel"  # BPMNs deployed from  Gazelle but probably eventually belong in ph-ee-env-template 
  local bpms_to_deploy=$(ls -l "$BPMNS_DIR"/*.bpmn | wc -l)
  printf "    Deploying BPMN diagrams from $BPMNS_DIR "

  # Find each .bpmn file in the specified directories and iterate over them
  for file in "$BPMNS_DIR"/*.bpmn;  do
    # Check if the glob expanded to an actual file or just returned the pattern
    if [ -f "$file" ]; then
      # Construct and execute the curl command for each file
      local cmd="curl --insecure --location --request POST $host \
          --header 'Platform-TenantId: greenbank' \
          --form 'file=@\"$file\"' \
          -s -o /dev/null -w '%{http_code}'"

      if [ "$DEBUG" = true ]; then
          echo "Executing: $cmd"
          http_code=$(eval "$cmd")
          exit_code=$?
          echo "HTTP Code: $http_code"
          echo "Exit code: $exit_code"
      else
          http_code=$(eval "$cmd")
          exit_code=$?
      fi 

      if [ "$exit_code" -eq 0 ] && [ "$http_code" -eq 200 ]; then
          ((successful_uploads++))
      fi
    else
      echo -e "${RED}** Warning : No BPMN files found in $BPMNS_DIR ${RESET}" 
    fi
  done

  # Check if the number of successful uploads meets the required threshold
  if [ "$successful_uploads" -ge "$bpms_to_deploy" ]; then
    echo " [ok] "
  else
    echo -e "${RED}Warning: there was an issue deploying the BPMN diagrams."
    echo -e "         run ./src/utils/deployBpmn-gazelle.sh to investigate${RESET}"
  fi
}

function createIngressSecret {
    local namespace="$1"
    local domain_name="$2"
    local secret_name="$3"
    key_dir="$HOME/.ssh"

    # Generate private key
    openssl genrsa -out "$key_dir/$domain_name.key" 2048 >> /dev/null 2>&1 

    # Generate self-signed certificate
    openssl req -x509 -new -nodes -key "$key_dir/$domain_name.key" -sha256 -days 365 -out "$key_dir/$domain_name.crt" -subj "/CN=$domain_name" -extensions v3_req -config <(
    cat <<EOF
    [req]
    distinguished_name = req_distinguished_name
    x509_extensions = v3_req
    prompt = no
    [req_distinguished_name]
    CN = $domain_name
    [v3_req]
    subjectAltName = @alt_names
    keyUsage = critical, digitalSignature, keyEncipherment
    extendedKeyUsage = serverAuth
    [alt_names]
    DNS.1 = $domain_name
EOF
) > /dev/null 2>&1 
    # Verify the certificate
    openssl x509 -in "$key_dir/$domain_name.crt" -noout -text > /dev/null 2>&1 

    # Create the Kubernetes TLS secret
    kubectl create secret tls "$secret_name" --cert="$key_dir/$domain_name.crt" --key="$key_dir/$domain_name.key" -n "$namespace" > /dev/null 2>&1 

    if [ $? -eq 0 ]; then
      echo "    Self-signed certificate and secret $secret_name created successfully in namespace $namespace "
    else
      echo " ** Error creating Self-signed certificate and secret $secret_name in namespace $namespace "
      exit 1 
    fi 
} 

function manageElasticSecrets {
    local action="$1"
    local namespace="$2"
    local certdir="$3" # location of the .p12 and .pem files 
    local password="XVYgwycNuEygEEEI0hQF"  #see 

    # Create a temporary directory to store the generated files
    temp_dir=$(mktemp -d)

    if [[ "$action" == "create" ]]; then
      echo "    creating elastic and kibana secrets in namespace $namespace" 
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
          deployment_available=$(kubectl get deployment "$deployment_name" -n "default" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
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
            printf "Deleting all resources in namespace $namespace "
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

  if [ -n "$values_file" ]; then
      echo "Installing Helm chart using values: $values_file..."
      su - $k8s_user -c "helm install --wait --timeout 600s $release_name $chart_dir -n $namespace -f $values_file"
  else
      echo "Installing Helm chart using default values file ..."
      su - $k8s_user -c "helm install --wait --timeout 600s $release_name $chart_dir -n $namespace "
  fi

  # Use kubectl to get the resource count in the specified namespace
  resource_count=$(sudo -u $k8s_user kubectl get pods -n "$namespace" --ignore-not-found=true 2>/dev/null | grep -v "No resources found" | wc -l)
  # Check if the deployment was successful
  if [ $resource_count -gt 0 ]; then
    echo "Helm chart deployed successfully."
  else
    echo -e "${RED}Helm chart deployment failed.${RESET}"
  fi

}

function preparePaymentHubChart(){
  # Clone the repositories
  cloneRepo "$PHBRANCH" "$PH_REPO_LINK" "$APPS_DIR" "$PHREPO_DIR"  # needed for kibana and elastic secrets only 
  cloneRepo "$PH_EE_ENV_TEMPLATE_REPO_BRANCH" "$PH_EE_ENV_TEMPLATE_REPO_LINK" "$APPS_DIR" "$PH_EE_ENV_TEMPLATE_REPO_DIR"

  # Update helm dependencies and repo index for ph-ee-engine
  echo "    updating dependencies ph-ee-engine chart "
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
  local releaseName="$PH_RELEASE_NAME"
  local timeout="600s"

  # Construct install command
  local helm_cmd="helm install $releaseName $chartDir -n $namespace --wait --timeout $timeout"
  if [ -n "$valuesFile" ]; then
    helm_cmd="$helm_cmd -f $valuesFile"
    echo "    Installing Helm chart with values file: $valuesFile"
  else
    echo "    Installing Helm chart with default values..."
  fi

  # Run the install command and capture exit status
  if [ "$debug" = true ]; then
    echo "🔧 Running as $k8s_user: $helm_cmd"
    su - "$k8s_user" -c "bash -c '$helm_cmd'"
    install_exit_code=$?
  else
    output=$(su - "$k8s_user" -c "bash -c '$helm_cmd'" 2>&1)
    install_exit_code=$?
  fi

  # Verify status after install
  su - "$k8s_user" -c "helm status $releaseName -n $namespace" > /tmp/helm_status_output 2>&1
  local status_exit_code=$?

  if grep -q "^STATUS: deployed" /tmp/helm_status_output; then
    echo "    Helm release '$releaseName' deployed successfully."
    return 0
  else
    echo -e "${RED}    ❌ Helm install of release '$releaseName' has failed :${RESET}"
    exit 1
  fi
}

function deployPH(){
  # TODO make this a global variable
  gazelleChartPath="$APPS_DIR/$PH_EE_ENV_TEMPLATE_REPO_DIR/helm/gazelle"
  result=$(isDeployed "phee" "$PHEE_NAMESPACE" "ph-ee-connector-mojaloop-java" )
  if [[ "$result" == "true" ]]; then
    if [[ "$redeploy" == "false" ]]; then
      echo "$PH_RELEASE_NAME is already deployed. Skipping deployment."
      return
    else # need to delete prior to redeploy 
      deleteResourcesInNamespaceMatchingPattern "$PH_NAMESPACE"
      deleteResourcesInNamespaceMatchingPattern "default"  #just removes prometheus at the moment
      manageElasticSecrets delete "$INFRA_NAMESPACE" "$APPS_DIR/$PHREPO_DIR/helm/es-secret"
      rm -f "$APPS_DIR/$PH_EE_ENV_TEMPLATE_REPO_DIR/helm/ph-ee-engine/charts/*tgz"
      rm -f "$APPS_DIR/$PH_EE_ENV_TEMPLATE_REPO_DIR/helm/gazelle/charts/*tgz"
    fi
  fi 
  echo "Deploying PaymentHub EE"
  createNamespace "$PH_NAMESPACE"
  checkPHEEDependencies
  preparePaymentHubChart
  manageElasticSecrets create "$PH_NAMESPACE" "$APPS_DIR/$PHREPO_DIR/helm/es-secret"
  manageElasticSecrets create "$INFRA_NAMESPACE" "$APPS_DIR/$PHREPO_DIR/helm/es-secret"
  createIngressSecret "$PH_NAMESPACE" "$GAZELLE_DOMAIN" sandbox-secret
  
  # now deploy the helm chart 
  deployPhHelmChartFromDir "$PH_NAMESPACE" "$gazelleChartPath" "$PH_VALUES_FILE"
  # now load the BPMS diagrams we do it here not in the helm chart so that 
  # we can count the sucessful BPMN uploads and be confident that they are working 
  #deployBPMS
  echo -e "\n${GREEN}============================"
  echo -e "Paymenthub Deployed"
  echo -e "============================${RESET}\n"
}

function createNamespace () {
  local namespace=$1
  printf "    Creating namespace $namespace "
  # Check if the namespace already exists
  if kubectl get namespace "$namespace" >> /dev/null 2>&1; then
      echo -e "${BLUE}Namespace $namespace already exists -skipping creation.${RESET}"
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
  result=$(isDeployed "infra" "$INFRA_NAMESPACE" "mysql-0")
  if [[ "$result" == "true" ]]; then
      if [[ "$redeploy" == "false" ]]; then
          echo "    infrastructure is already deployed. Skipping deployment."
          return
      else
          deleteResourcesInNamespaceMatchingPattern "$INFRA_NAMESPACE"
      fi
  fi

  createNamespace $INFRA_NAMESPACE

  # Update helm dependencies and repo index for infra chart 
  printf  "    updating dependencies for infra helm chart "
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

    # Apply persistence-related manifests first
    for file in "$directory"/*persistence*.yaml; do
      if [ -f "$file" ]; then
        su - $k8s_user -c "kubectl apply -f $file -n $namespace" >> /dev/null 2>&1
        if [ $? -ne 0 ]; then
          echo -e "${RED}Failed to apply persistence manifest $file.${RESET}"
        fi
      fi
    done

    # Apply other manifests
    for file in "$directory"/*.yaml; do
      if [[ "$file" != *persistence*.yaml ]]; then
        su - $k8s_user -c "kubectl apply -f $file -n $namespace" >> /dev/null 2>&1
        if [ $? -ne 0 ]; then
          echo -e "${RED}Failed to apply Kubernetes manifest $file.${RESET}"
        fi
      fi
    done
    # su - $k8s_user -c "kubectl apply -f $directory -n $namespace"  >> /dev/null 2>&1 
    # if [ $? -eq 0 ]; then
    #     echo -e "    Kubernetes manifests applied successfully."
    # else
    #     echo -e "${RED}Failed to apply Kubernetes manifests.${RESET}"
    # fi
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

function vnext_restore_demo_data {
  local mongo_data_dir=$1
  local mongo_dump_file=$2
  local namespace=$3 
  printf "    restoring vNext mongodb demonstration/test data "
  mongopod=`kubectl get pods --namespace $namespace | grep -i mongodb |awk '{print $1}'` 
  mongo_root_pw=`kubectl get secret --namespace $namespace  mongodb  -o jsonpath='{.data.MONGO_INITDB_ROOT_PASSWORD}'| base64 -d` 
  if [[ -z "$mongo_root_pw" ]]; then
    echo -e "${RED}   Restore Failed to retrieve MongoDB root password from secret in namespace '$namespace'${RESET}" 
    return 1
  fi
  kubectl cp  $mongo_data_dir/$mongo_dump_file $mongopod:/tmp/mongodump.gz  --namespace $namespace  >/dev/null 2>&1 # copy the demo / test data into the mongodb pod
  # Execute mongorestore
  if ! kubectl exec --namespace "$namespace" --stdin --tty "$mongopod" -- mongorestore -u root -p "$mongo_root_pw" \
      --gzip --archive=/tmp/mongodump.gz --authenticationDatabase admin >/dev/null 2>&1; then
    echo -e "${RED}   mongorestore command failed ${RESET}" 
    return 1
  fi
  printf " [ ok ] \n"
}

function vnext_configure_ttk {
  local ttk_files_dir=$1
  local namespace=$2
  local warning_issued=false
  printf "\n==> Configuring the Testing Toolkit... "

  # Check if BlueBank pod is running => remember 
  local bb_pod_status
  bb_pod_status=$(kubectl get pods bluebank-backend-0 --namespace "$namespace" --no-headers 2>/dev/null | awk '{print $3}')
  
  if [[ "$bb_pod_status" != "Running" ]]; then
    printf "    - TTK pod is not running; skipping configuration (note TTK may not support arm64).\n"
    printf "    - Note: TTK is not essential for Mifos Gazelle deployments \n"
    return 0
  fi

  # Define TTK pod destinations
  local ttk_pod_env_dest="/opt/app/examples/environments"
  local ttk_pod_spec_dest="/opt/app/spec_files"
  
  # Function to check and report on kubectl cp command success
  check_kubectl_cp() {
    if ! kubectl cp "$1" "$2" --namespace "$namespace" 2>/dev/null; then
      printf "    [WARNING] Failed to copy %s to %s\n" "$1" "$2"
      warning_issued=true
    fi
  }
  
  # Copy BlueBank files
  check_kubectl_cp "$ttk_files_dir/environment/hub_local_environment.json" "bluebank-backend-0:$ttk_pod_env_dest/hub_local_environment.json"
  check_kubectl_cp "$ttk_files_dir/environment/dfsp_local_environment.json" "bluebank-backend-0:$ttk_pod_env_dest/dfsp_local_environment.json"
  check_kubectl_cp "$ttk_files_dir/spec_files/user_config_bluebank.json" "bluebank-backend-0:$ttk_pod_spec_dest/user_config.json"
  check_kubectl_cp "$ttk_files_dir/spec_files/default.json" "bluebank-backend-0:$ttk_pod_spec_dest/rules_callback/default.json"
  
  # Copy GreenBank files
  check_kubectl_cp "$ttk_files_dir/environment/hub_local_environment.json" "greenbank-backend-0:$ttk_pod_env_dest/hub_local_environment.json"
  check_kubectl_cp "$ttk_files_dir/environment/dfsp_local_environment.json" "greenbank-backend-0:$ttk_pod_env_dest/dfsp_local_environment.json"
  check_kubectl_cp "$ttk_files_dir/spec_files/user_config_greenbank.json" "greenbank-backend-0:$ttk_pod_spec_dest/user_config.json"
  check_kubectl_cp "$ttk_files_dir/spec_files/default.json" "greenbank-backend-0:$ttk_pod_spec_dest/rules_callback/default.json"

  # Final status message
  if [[ "$warning_issued" == false ]]; then
    printf "    [ ok ] \n"
  else
    printf "    [ WARNING ] Some files failed to copy. Check warnings above.\n"
  fi
}


function deployvNext() {
  printf "\n==> Deploying Mojaloop vNext application \n"
  
  result=$(isDeployed "vnext" "$VNEXT_NAMESPACE" "reporting-api-svc" )
  if [[ "$result" == "true" ]]; then
    if [[ "$redeploy" == "false" ]]; then
      echo "    vNext application is already deployed. Skipping deployment."
      return
    else # need to delete prior to redeploy 
      deleteResourcesInNamespaceMatchingPattern "$VNEXT_NAMESPACE"
    fi
  fi 
  createNamespace "$VNEXT_NAMESPACE"
  cloneRepo "$VNEXTBRANCH" "$VNEXT_REPO_LINK" "$APPS_DIR" "$VNEXTREPO_DIR"
  # remove the TTK-CLI pod as it is not needed and comes up in error mode 
  rm  -f "$APPS_DIR/$VNEXTREPO_DIR/packages/installer/manifests/ttk/ttk-cli.yaml" > /dev/null 2>&1
  configurevNext  # make any local mods to manifests
  vnext_restore_demo_data $CONFIG_DIR "mongodump.gz" $INFRA_NAMESPACE
  for index in "${!VNEXT_LAYER_DIRS[@]}"; do
    folder="${VNEXT_LAYER_DIRS[index]}"
    applyKubeManifests "$folder" "$VNEXT_NAMESPACE" #>/dev/null 2>&1
    if [ "$index" -eq 0 ]; then
      echo -e "${BLUE}    Waiting for vnext cross cutting concerns to come up${RESET}"
      sleep 10
      echo -e "    Proceeding ..."
    fi
  done
  ## don't do this by default for gazelle v1.1.0 as for v1.1.0 we now have Mifos greenbank/bluebank as much more realistic DFSPs 
  ## It is true that in for vNext or subseqent we might want TTKs for debug and testing purposes hence leaving this here for the moment
  ## vnext_configure_ttk $VNEXT_TTK_FILES_DIR  $VNEXT_NAMESPACE   # configure in the TTKs as participants 

  echo -e "\n${GREEN}============================"
  echo -e "vnext Deployed"
  echo -e "============================${RESET}\n"

}
function DeployMifosXfromYaml() {
    manifests_dir=$1
    timeout_secs=${2:-600}  # Default timeout of 10 minutes if not specified
    echo "==> Deploying MifosX i.e. web-app and fineract via application manifests"
    createNamespace "$MIFOSX_NAMESPACE"
    cloneRepo "$MIFOSX_BRANCH" "$MIFOSX_REPO_LINK" "$APPS_DIR" "$MIFOSX_REPO_DIR"
    
    # Restore the database dump before starting MifosX
    # Assumes FINERACT_LIQUIBASE_ENABLED=false in fineract deployment
    echo "    Restoring MifosX database dump "
    $UTILS_DIR/dump-restore-fineract-db.sh -r > /dev/null
    
    echo "    deploying MifosX manifests from $manifests_dir"
    applyKubeManifests "$manifests_dir" "$MIFOSX_NAMESPACE"
    
    # Wait for fineract-server pod to be ready
    echo "    Waiting for fineract-server pod to be ready (timeout: ${timeout_secs}s)..."
    if kubectl wait --for=condition=Ready pod -l app=fineract-server \
        --namespace="$MIFOSX_NAMESPACE" --timeout="${timeout_secs}s" > /dev/null 2>&1 ; then
        echo "    MifosX  is  ready"
    else
        echo -e "${RED} ERROR: MifosX fineract-server pod failed to become ready within ${timeout_secs} seconds ${RESET}"
        return 1
    fi  
    echo -e "\n${GREEN}====================================="
    echo -e "MifosX (fineract + web app) Deployed"
    echo -e "=====================================${RESET}\n"
}

function generateMifosXandVNextData {
  # generate load and syncronize MifosX accounts and vNext Oracle associations  
  result_vnext=$(isDeployed "vnext" "$VNEXT_NAMESPACE" "reporting-api-svc" )
  result_mifosx=$(isDeployed "mifosx" "$MIFOSX_NAMESPACE" "fineract-server" )

  if [[ "$result_vnext" == "true" ]]  && [[ "$result_mifosx" == "true" ]] ; then
    echo -e "${BLUE}Generating MifosX clients and accounts & registering associations with vNext Oracle ...${RESET}"
    $RUN_DIR/src/utils/data-loading/generate-mifos-vnext-data.py > /dev/null 2>&1
    if [[ "$?" -ne 0 ]]; then
      echo -e "${RED}Error generating vNext clients and accounts ${RESET}"
      echo " run $RUN_DIR/src/utils/data-loading/generate-mifos-vnext-data.py to investigate"
      return 1 
    fi
  else 
    echo -e "${YELLOW}vNext or MifosX is not running => skipping MifosX and vNext data generation ${RESET}"
  fi
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
  echo -e "kubectl get pods -n paymenthub #For testing PaymentHub EE "
  echo -e "kubectl get pods -n mifosx # for testing MifosX"
  echo -e "or install k9s by executing ./src/utils/install-k9s.sh <cr> in this terminal window\n\n"
}

function deleteApps {
  appsToDelete="$2"
  if [[ "$appsToDelete" == "all" ]]; then
    deleteResourcesInNamespaceMatchingPattern "$MIFOSX_NAMESPACE"
    deleteResourcesInNamespaceMatchingPattern "$VNEXT_NAMESPACE"
    deleteResourcesInNamespaceMatchingPattern "$PH_NAMESPACE"
    rm -f "$APPS_DIR/$PH_EE_ENV_TEMPLATE_REPO_DIR/helm/ph-ee-engine/charts/*tgz"
    rm -f "$APPS_DIR/$PH_EE_ENV_TEMPLATE_REPO_DIR/helm/gazelle/charts/*tgz"
    deleteResourcesInNamespaceMatchingPattern "$INFRA_NAMESPACE"
    deleteResourcesInNamespaceMatchingPattern "default"
  elif [[ "$appsToDelete" == "vnext" ]];then
    deleteResourcesInNamespaceMatchingPattern "$VNEXT_NAMESPACE"
  elif [[ "$appsToDelete" == "mifosx" ]]; then 
    deleteResourcesInNamespaceMatchingPattern "$MIFOSX_NAMESPACE"
  elif [[ "$appsToDelete" == "phee" ]]; then
    deleteResourcesInNamespaceMatchingPattern "$PH_NAMESPACE"
    rm  $APPS_DIR/$PH_EE_ENV_TEMPLATE_REPO_DIR/helm/ph-ee-engine/charts/*tgz
    rm  $APPS_DIR/$PH_EE_ENV_TEMPLATE_REPO_DIR/helm/gazelle/charts/*tgz
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
  appsToDeploy="$2"
  redeploy="$3"
  echo "redeploy is $redeploy"

  if [[ "$appsToDeploy" == "all" ]]; then
    echo -e "${BLUE}Deploying all apps ...${RESET}"
    deployInfrastructure "$redeploy" 
    deployvNext
    deployPH
    DeployMifosXfromYaml "$MIFOSX_MANIFESTS_DIR" 
    deployBPMS
    generateMifosXandVNextData
  elif [[ "$appsToDeploy" == "infra" ]];then
    deployInfrastructure
  elif [[ "$appsToDeploy" == "vnext" ]];then
    deployInfrastructure "false"
    deployvNext
  elif [[ "$appsToDeploy" == "mifosx" ]]; then 
    if [[ "$redeploy" == "true" ]]; then 
      echo "removing current mifosx and redeploying"
      deleteApps 1 "mifosx"
    fi 
    deployInfrastructure "false"
    DeployMifosXfromYaml "$MIFOSX_MANIFESTS_DIR" 
    generateMifosXandVNextData
  elif [[ "$appsToDeploy" == "phee" ]]; then
    deployInfrastructure "false"
    deployPH
  else 
    echo -e "${RED}Invalid option ${RESET}"
    showUsage
    exit 
  fi
  addKubeConfig >> /dev/null 2>&1
  printEndMessage
}
