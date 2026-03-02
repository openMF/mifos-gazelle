#!/usr/bin/env bash
# vnext.sh -- Mifos Gazelle deployer script for vNext Beta 1 switch 

#------------------------------------------------------------------------------
# Function : deployvNext
# Description: Deploys Mojaloop vNext using Kubernetes manifests.
#------------------------------------------------------------------------------
function deployvNext() {
  log_section "Deploying Mojaloop vNext"

  if is_app_running "$VNEXT_NAMESPACE"; then
    if [[ "$redeploy" == "false" ]]; then
      echo "    vNext already deployed — skipping."
      return
    fi
  fi

  log_step "Removing existing vNext resources"
  deleteResourcesInNamespaceMatchingPattern "$VNEXT_NAMESPACE"
  log_ok

  log_step "Creating namespace $VNEXT_NAMESPACE"
  createNamespace "$VNEXT_NAMESPACE"
  log_ok

  cloneRepo "$VNEXTBRANCH" "$VNEXT_REPO_LINK" "$APPS_DIR" "$VNEXTREPO_DIR"

  rm -f "$APPS_DIR/$VNEXTREPO_DIR/packages/installer/manifests/ttk/ttk-cli.yaml" > /dev/null 2>&1
  rm -rf "$APPS_DIR/$VNEXTREPO_DIR/packages/installer/manifests/infra" > /dev/null 2>&1

  log_step "Updating service URLs in manifests"
  update_vnext_service_urls "$APPS_DIR/vnext/packages/installer/manifests"
  log_ok

  log_step "Updating FQDNs in manifests"
  update_fqdn_batch "$APPS_DIR/vnext/packages/installer/manifests" "local" "$GAZELLE_DOMAIN"
  find "$APPS_DIR/$VNEXTREPO_DIR/packages/installer/manifests" -type f -name "*.yaml" | while read -r file; do
      perl -pi -e 's/ingressClassName:\s*nginx-ext/ingressClassName: nginx/' "$file"
  done
  log_ok

  log_step "Restoring vNext MongoDB demo data"
  vnext_restore_demo_data $CONFIG_DIR "mongodump.gz" $INFRA_NAMESPACE
  # log_ok is called inside vnext_restore_demo_data on success

  for index in "${!VNEXT_LAYER_DIRS[@]}"; do
    folder="${VNEXT_LAYER_DIRS[index]}"
    log_step "Applying layer $((index+1)) manifests"
    applyKubeManifests "$folder" "$VNEXT_NAMESPACE"
    log_ok
    if [ "$index" -eq 0 ]; then
      logWithVerboseCheck "$debug" "$DEBUG" "Cross-cutting concerns layer applied — proceeding"
    fi
  done

  log_banner "vNext Deployed"
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
        log_error "update_vnext_service_urls: directory argument required"
        return 1
    fi

    if [[ ! -d "$target_dir" ]]; then
        log_error "update_vnext_service_urls: directory '$target_dir' does not exist"
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
        log_error "vnext_restore_demo_data: missing required parameters"
        return 1
    fi

    if [ ! -d "$mongo_data_dir" ] || [ ! -r "$mongo_data_dir/$mongo_dump_file" ]; then
        log_error "mongo_data_dir '$mongo_data_dir' does not exist or '$mongo_dump_file' is not readable"
        return 1
    fi

    if ! su - "$k8s_user" -c "test -r '$mongo_data_dir/$mongo_dump_file'" 2>/dev/null; then
        local temp_dir
        temp_dir=$(mktemp -d -p "/tmp" "mongo_restore_XXXXXX") || { log_error "Failed to create temporary directory"; return 1; }
        cp "$mongo_data_dir/$mongo_dump_file" "$temp_dir/$mongo_dump_file" || { log_error "Failed to copy $mongo_dump_file to temp dir"; rm -rf "$temp_dir"; return 1; }
        chown "$k8s_user":"$k8s_user" "$temp_dir/$mongo_dump_file" || { log_error "Failed to change ownership of dump file"; rm -rf "$temp_dir"; return 1; }
        chmod 600 "$temp_dir/$mongo_dump_file" || { log_error "Failed to set permissions on dump file"; rm -rf "$temp_dir"; return 1; }
        mongo_data_dir="$temp_dir"
    fi

    local mongopod
    mongopod=$(run_as_user "kubectl get pods --namespace \"$namespace\" | grep -i mongodb | cut -d \" \" -f1") || { log_failed "Failed to retrieve MongoDB pod name"; rm -rf "${temp_dir:-}"; return 1; }
    if [ -z "$mongopod" ]; then
        log_failed "No MongoDB pod found in namespace '$namespace'"
        rm -rf "${temp_dir:-}"
        return 1
    fi

    local mongo_root_pw
    mongo_root_pw=$(run_as_user "kubectl get secret --namespace \"$namespace\" mongodb -o jsonpath='{.data.MONGO_INITDB_ROOT_PASSWORD}' | base64 -d") || { log_failed "Failed to retrieve MongoDB root password"; rm -rf "${temp_dir:-}"; return 1; }
    if [ -z "$mongo_root_pw" ]; then
        log_failed "MongoDB root password is empty in namespace '$namespace'"
        rm -rf "${temp_dir:-}"
        return 1
    fi

    if ! su - "$k8s_user" -c "kubectl cp \"$mongo_data_dir/$mongo_dump_file\" \"$namespace/$mongopod:/tmp/mongodump.gz\"" > /dev/null 2>&1; then
        log_failed "Failed to copy $mongo_dump_file to pod $mongopod"
        rm -rf "${temp_dir:-}"
        return 1
    fi

    if ! run_as_user "kubectl exec --namespace \"$namespace\" --stdin --tty \"$mongopod\" -- mongorestore -u root -p \"$mongo_root_pw\" --gzip --archive=/tmp/mongodump.gz --authenticationDatabase admin" > /dev/null 2>&1; then
        log_failed "mongorestore failed"
        rm -rf "${temp_dir:-}"
        return 1
    fi

    rm -rf "${temp_dir:-}"
    log_ok
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
  log_section "Configuring the Testing Toolkit"

  local bb_pod_status
  bb_pod_status=$(kubectl get pods bluebank-backend-0 --namespace "$namespace" --no-headers 2>/dev/null | awk '{print $3}')

  if [[ "$bb_pod_status" != "Running" ]]; then
    echo "    TTK pod not running — skipping (TTK may not support arm64 and is not essential)"
    return 0
  fi

  # Define TTK pod destinations
  local ttk_pod_env_dest="/opt/app/examples/environments"
  local ttk_pod_spec_dest="/opt/app/spec_files"
  
  # Function to check and report on kubectl cp command success
  check_kubectl_cp() {
    if ! kubectl cp "$1" "$2" --namespace "$namespace" 2>/dev/null; then
      log_warn "Failed to copy $(basename $1) to $2"
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
    log_ok
  else
    log_warn "Some TTK files failed to copy."
  fi
}