#!/usr/bin/env bash
# vnext.sh -- Mifos Gazelle deployer script for vNext Beta 1 switch 

#------------------------------------------------------------------------------
# Function : deploy_vnext
# Description: Deploys Mojaloop vNext using Kubernetes manifests.
#------------------------------------------------------------------------------
deploy_vnext() {
  log_section "Deploying Mojaloop vNext"

  if is_app_running "$VNEXT_NAMESPACE"; then
    if [[ "$redeploy" == "false" ]]; then
      echo "    vNext already deployed — skipping."
      return
    fi
  fi

  log_step "Removing existing vNext resources"
  delete_resources_in_namespace_matching_pattern "$VNEXT_NAMESPACE"
  log_ok

  log_step "Creating namespace $VNEXT_NAMESPACE"
  create_namespace "$VNEXT_NAMESPACE"
  log_ok

  log_step "Copying vendored vNext manifests to working directory"
  mkdir -p "$APPS_DIR/vnext/packages/installer/manifests"
  cp -r "$BASE_DIR/src/deployer/manifests/vnext/." "$APPS_DIR/vnext/packages/installer/manifests/"
  log_ok

  log_step "Updating FQDNs in manifests"
  apply_domain_to_dir "$APPS_DIR/vnext/packages/installer/manifests" "$GAZELLE_DOMAIN" "local"
  log_ok

  log_step "Restoring vNext MongoDB demo data"
  vnext_restore_demo_data $CONFIG_DIR "mongodump.gz" $INFRA_NAMESPACE
  # log_ok is called inside vnext_restore_demo_data on success

  local last_layer_index=$(( ${#VNEXT_LAYER_DIRS[@]} - 1 ))
  for index in "${!VNEXT_LAYER_DIRS[@]}"; do
    folder="${VNEXT_LAYER_DIRS[index]}"
    log_step "Applying layer $((index+1)) manifests"
    apply_kube_manifests "$folder" "$VNEXT_NAMESPACE"
    log_ok
    if [[ "$index" -lt "$last_layer_index" ]]; then
      wait_for_pods_ready "$VNEXT_NAMESPACE" "${startup_timeout:-600}" || \
        log_warn "vNext layer $((index+1)) pods did not fully stabilise — continuing with next layer"
    fi
  done

  log_banner "vNext Deployed"
}

#------------------------------------------------------------------------------
# Function : vnext_restore_demo_data
# Description: Restores demonstration/test data into vNext MongoDB from a dump file.
# Parameters:
#   $1 - Directory containing the MongoDB dump file.
#   $2 - Name of the MongoDB dump file (e.g., mongodump.gz).
#   $3 - Kubernetes namespace where vNext is deployed.
#------------------------------------------------------------------------------
vnext_restore_demo_data() {
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

    local mongopod
    mongopod=$(kubectl get pods --namespace "$namespace" 2>/dev/null | grep -i mongodb | cut -d " " -f1) || { log_failed "Failed to retrieve MongoDB pod name"; return 1; }
    if [ -z "$mongopod" ]; then
        log_failed "No MongoDB pod found in namespace '$namespace'"
        return 1
    fi

    local mongo_root_pw
    mongo_root_pw=$(kubectl get secret --namespace "$namespace" mongodb -o jsonpath='{.data.MONGO_INITDB_ROOT_PASSWORD}' 2>/dev/null | base64 -d) || { log_failed "Failed to retrieve MongoDB root password"; return 1; }
    if [ -z "$mongo_root_pw" ]; then
        log_failed "MongoDB root password is empty in namespace '$namespace'"
        return 1
    fi

    if ! kubectl cp "$mongo_data_dir/$mongo_dump_file" "$namespace/$mongopod:/tmp/mongodump.gz" > /dev/null 2>&1; then
        log_failed "Failed to copy $mongo_dump_file to pod $mongopod"
        return 1
    fi

    if ! kubectl exec --namespace "$namespace" "$mongopod" -- mongorestore -u root -p "$mongo_root_pw" --gzip --archive=/tmp/mongodump.gz --authenticationDatabase admin > /dev/null 2>&1; then
        log_failed "mongorestore failed"
        return 1
    fi

    rm -rf "${temp_dir:-}"
    log_ok
}
