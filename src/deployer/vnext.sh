#!/usr/bin/env bash
# vnext.sh -- Mifos Gazelle deployer script for vNext Beta 1 switch 

#------------------------------------------------------------------------------
# Function : deployvNext
# Description: Deploys Mojaloop vNext using Kubernetes manifests.
#------------------------------------------------------------------------------
function deployvNext() {
  printf "\n==> Deploying Mojaloop vNext application \n"
  
  if is_app_running  "$VNEXT_NAMESPACE"; then
    if [[ "$redeploy" == "false" ]]; then
      echo "    vNext application is already deployed. Skipping deployment."
      return
    fi
  fi 

  # We are deploying or redeploying => make sure things are cleaned up first
  printf "    Redeploying vNext: Deleting existing resources in namespace %s\n" "$VNEXT_NAMESPACE"
  deleteResourcesInNamespaceMatchingPattern "$VNEXT_NAMESPACE"
  createNamespace "$VNEXT_NAMESPACE"
  cloneRepo "$VNEXTBRANCH" "$VNEXT_REPO_LINK" "$APPS_DIR" "$VNEXTREPO_DIR"

  # remove the manifests dir and TTK-CLI as they are not used in Gazelle v1.1.0
  # and can complicate updates for services URLs and ingress hosts 
  rm  -f "$APPS_DIR/$VNEXTREPO_DIR/packages/installer/manifests/ttk/ttk-cli.yaml" > /dev/null 2>&1
  rm -rf "$APPS_DIR/$VNEXTREPO_DIR/packages/installer/manifests/infra" > /dev/null 2>&1

  echo "    Updating service URLs in vNext manifests to use cluster-local addresses"
  update_vnext_service_urls "$APPS_DIR/vnext/packages/installer/manifests"

  echo "    Updating FQDNs in vNext manifests to use domain $GAZELLE_DOMAIN"
  update_fqdn_batch "$APPS_DIR/vnext/packages/installer/manifests"  "local" "$GAZELLE_DOMAIN"

  # update the ingress class name from nginx-ext to nginx
  find "$APPS_DIR/$VNEXTREPO_DIR/packages/installer/manifests" -type f -name "*.yaml" | while read -r file; do
      perl -pi -e 's/ingressClassName:\s*nginx-ext/ingressClassName: nginx/' "$file"
  done

  vnext_restore_demo_data $CONFIG_DIR "mongodump.gz" $INFRA_NAMESPACE
  for index in "${!VNEXT_LAYER_DIRS[@]}"; do
    folder="${VNEXT_LAYER_DIRS[index]}"
    applyKubeManifests "$folder" "$VNEXT_NAMESPACE" #>/dev/null 2>&1
    if [ "$index" -eq 0 ]; then
      echo -e "${BLUE}    Waiting for vnext cross cutting concerns to come up${RESET}"
      # run_as_user "kubectl wait --for=condition=ready pod --all -n infra --timeout=1000s"
      #wait_for_pods_ready "$INFRA_NAMESPACE"
      echo -e "    Infra is up & running proceeding ..."
    fi
  done

  echo -e "\n${GREEN}============================"
  echo -e "vnext Deployed"
  echo -e "============================${RESET}\n"
}

#------------------------------------------------------------------------------
# Function : update_vnext_service_urls
# Description: Updates service URLs in vNext manifests to use cluster-local addresses.
# Parameters:
#   $1 - Directory containing the vNext manifests.
#------------------------------------------------------------------------------
function update_vnext_service_urls() {
    local target_dir="$1"
    
    # Check if directory parameter is provided
    if [[ -z "$target_dir" ]]; then
        echo "Error: No directory specified."
        echo "Usage: update_vnext_service_urls <directory>"
        return 1
    fi
    
    # Check if directory exists
    if [[ ! -d "$target_dir" ]]; then
        echo "Error: Directory '$target_dir' does not exist."
        return 1
    fi
    #echo "    Updating service URLs in: $target_dir"
    
    # Find all YAML files and apply replacements (idempotent - won't duplicate if run multiple times)
    find "$target_dir" -type f \( -name "*.yaml" -o -name "*.yml" \) -exec sed -i \
        -e 's|value: kafka:9092$|value: kafka.infra.svc.cluster.local:9092|g' \
        -e 's|value: mongodb://root:mongoDbPas42@mongodb:27017/\s*$|value: mongodb://root:mongoDbPas42@mongodb.infra.svc.cluster.local:27017/|g' \
        -e 's|value: redis-master$|value: redis-master.infra.svc.cluster.local|g' \
        -e 's|value: http://infra-elasticsearch:9200$|value: http://infra-elasticsearch.infra.svc.cluster.local:9200|g' \
        {} \; 
    
    #echo "Service URL updates complete."
}

#------------------------------------------------------------------------------
# Function : vnext_restore_demo_data
# Description: Restores demonstration/test data into vNext MongoDB from a dump file.
# Parameters:
#   $1 - Directory containing the MongoDB dump file.
#   $2 - Name of the MongoDB dump file (e.g., mongodump.gz).
#   $3 - Kubernetes namespace where vNext is deployed.
#------------------------------------------------------------------------------
function vnext_restore_demo_data {
    local mongo_data_dir="$1"
    local mongo_dump_file="$2"
    local namespace="$3"

    # Verify input parameters
    if [ -z "$mongo_data_dir" ] || [ -z "$mongo_dump_file" ] || [ -z "$namespace" ]; then
        echo " ** Error: Missing required parameters (mongo_data_dir, mongo_dump_file, namespace)"
        return 1
    fi

    # Verify mongo_data_dir and mongo_dump_file exist and are readable
    if [ ! -d "$mongo_data_dir" ] || [ ! -r "$mongo_data_dir/$mongo_dump_file" ]; then
        echo " ** Error: mongo_data_dir $mongo_data_dir does not exist or $mongo_dump_file is not readable"
        return 1
    fi

    # Check if k8s_user can access the dump file
    if ! su - "$k8s_user" -c "test -r '$mongo_data_dir/$mongo_dump_file'" 2>/dev/null; then
        # Copy dump file to a temporary directory accessible to k8s_user
        local temp_dir
        temp_dir=$(mktemp -d -p "/tmp" "mongo_restore_XXXXXX") || { echo " ** Error: Failed to create temporary directory"; return 1; }
        cp "$mongo_data_dir/$mongo_dump_file" "$temp_dir/$mongo_dump_file" || { echo " ** Error: Failed to copy $mongo_dump_file to temporary directory"; rm -rf "$temp_dir"; return 1; }
        chown "$k8s_user":"$k8s_user" "$temp_dir/$mongo_dump_file" || { echo " ** Error: Failed to change ownership of copied dump file"; rm -rf "$temp_dir"; return 1; }
        chmod 600 "$temp_dir/$mongo_dump_file" || { echo " ** Error: Failed to set permissions on copied dump file"; rm -rf "$temp_dir"; return 1; }
        mongo_data_dir="$temp_dir"
    fi

    printf "    restoring vNext mongodb demonstration/test data "

    # Get MongoDB pod name using run_as_user
    local mongopod
    mongopod=$(run_as_user "kubectl get pods --namespace \"$namespace\" | grep -i mongodb | cut -d \" \" -f1") || { echo -e "\n ** Error: Failed to retrieve MongoDB pod name"; rm -rf "${temp_dir:-}"; return 1; }
    if [ -z "$mongopod" ]; then
        echo -e "\n ** Error: No MongoDB pod found in namespace '$namespace'"
        rm -rf "${temp_dir:-}"
        return 1
    fi

    # Get MongoDB root password using run_as_user
    local mongo_root_pw
    mongo_root_pw=$(run_as_user "kubectl get secret --namespace \"$namespace\" mongodb -o jsonpath='{.data.MONGO_INITDB_ROOT_PASSWORD}' | base64 -d") || { echo -e "\n ** Error: Failed to retrieve MongoDB root password from secret"; rm -rf "${temp_dir:-}"; return 1; }
    if [ -z "$mongo_root_pw" ]; then
        echo -e "\n ** Error: MongoDB root password is empty in namespace '$namespace'"
        rm -rf "${temp_dir:-}"
        return 1
    fi

    if ! su - "$k8s_user" -c "kubectl cp \"$mongo_data_dir/$mongo_dump_file\" \"$namespace/$mongopod:/tmp/mongodump.gz\"" > /dev/null 2>&1 ;  then
        echo -e "\n ** Error: Failed to copy $mongo_dump_file to pod $mongopod"
        rm -rf "${temp_dir:-}"
        return 1
    fi

    # Execute mongorestore using run_as_user
    if ! run_as_user "kubectl exec --namespace \"$namespace\" --stdin --tty \"$mongopod\" -- mongorestore -u root -p \"$mongo_root_pw\" --gzip --archive=/tmp/mongodump.gz --authenticationDatabase admin" > /dev/null 2>&1 ; then
        echo -e "\n ** Error: mongorestore command failed"
        rm -rf "${temp_dir:-}"
        return 1
    fi

    rm -rf "${temp_dir:-}"  # Clean up temporary directory if created
    printf " [ ok ]\n"
}

#------------------------------------------------------------------------------
# NOTE: this is not used in Gazelle v1.1.0 but may be useful in future releases
# Function : vnext_configure_ttk
# Description: Configures the Testing Toolkit (TTK) in the vNext deployment by copying
#              necessary environment and specification files into the TTK pods.
# Parameters:
#   $1 - Directory containing the TTK files to be copied.
#   $2 - Kubernetes namespace where vNext is deployed.
#------------------------------------------------------------------------------
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