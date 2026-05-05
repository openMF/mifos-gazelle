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

  clone_repo "$VNEXTBRANCH" "$VNEXT_REPO_LINK" "$APPS_DIR" "$VNEXTREPO_DIR"

  rm -f "$APPS_DIR/$VNEXTREPO_DIR/packages/installer/manifests/ttk/ttk-cli.yaml" > /dev/null 2>&1
  rm -rf "$APPS_DIR/$VNEXTREPO_DIR/packages/installer/manifests/infra" > /dev/null 2>&1

  log_step "Updating service URLs in manifests"
  update_vnext_service_urls "$APPS_DIR/vnext/packages/installer/manifests"
  log_ok

  log_step "Fixing liveness probes in manifests"
  fix_vnext_liveness_probes "$APPS_DIR/vnext/packages/installer/manifests"
  log_ok

  log_step "Updating FQDNs in manifests"
  apply_domain_to_dir "$APPS_DIR/vnext/packages/installer/manifests" "$GAZELLE_DOMAIN" "local"
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
    apply_kube_manifests "$folder" "$VNEXT_NAMESPACE"
    log_ok
    if [ "$index" -eq 0 ]; then
      log_with_verbose_check "$debug" "$DEBUG" "Cross-cutting concerns layer applied — proceeding"
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
update_vnext_service_urls() {
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
    while IFS= read -r -d '' f; do
        sed_inplace \
            -e 's|value: kafka:9092$|value: kafka.infra.svc.cluster.local:9092|g' \
            -e 's|value: mongodb://root:mongoDbPas42@mongodb:27017/[[:space:]]*$|value: mongodb://root:mongoDbPas42@mongodb.infra.svc.cluster.local:27017/|g' \
            -e 's|value: redis-master$|value: redis-master.infra.svc.cluster.local|g' \
            -e 's|value: http://infra-elasticsearch:9200$|value: http://infra-elasticsearch.infra.svc.cluster.local:9200|g' \
            "$f"
    done < <(find "$target_dir" -type f \( -name "*.yaml" -o -name "*.yml" \) -print0) 
    
    #echo "Service URL updates complete."
}

#------------------------------------------------------------------------------
# Function : fix_vnext_liveness_probes
# Description: Replaces broken nc-based exec liveness probes with tcpSocket probes.
#
# The upstream vNext manifests use a single-element exec command:
#   command:
#   - nc -z localhost PORT || exit -1
#
# Linux exec() treats the entire string as the binary name (spaces included),
# so the probe always fails and the kubelet kills the pod after 10 attempts.
# tcpSocket probes are checked by the kubelet externally — no tooling needed
# inside the container.
#
# Also fixes a bug in the upstream reporting-api-svc manifest where the probe
# checked port 5005 but the service listens on 5000.
#
# TODO: remove this function once vNext manifests are vendored into Gazelle
#       and the probes are corrected at source.
# Parameters:
#   $1 - Directory containing the vNext manifests.
#------------------------------------------------------------------------------
fix_vnext_liveness_probes() {
    local target_dir="$1"

    if [[ -z "$target_dir" ]] || [[ ! -d "$target_dir" ]]; then
        log_error "fix_vnext_liveness_probes: directory '$target_dir' does not exist"
        return 1
    fi

    while IFS= read -r -d '' f; do
        perl -0777 -pi -e '
            s{(\n([ ]+)livenessProbe:\n)[ ]+exec:\n[ ]+command:\n[ ]+- nc -z localhost (\d+) \|\| exit -1\n}
             {$1 . $2 . "  tcpSocket:\n" . $2 . "    port: " . $3 . "\n"}ge
        ' "$f"
    done < <(find "$target_dir" -type f -name "*.yaml" -print0)

    # The upstream reporting-api-svc manifest had nc -z on port 5005 but the
    # service listens on 5000 — correct the port after the probe type is fixed.
    local reporting_api="$target_dir/reporting/reporting-api-svc-deployment.yaml"
    if [[ -f "$reporting_api" ]]; then
        sed_inplace -e 's/port: 5005/port: 5000/' "$reporting_api"
    fi
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

    if ! run_as_user "kubectl exec --namespace \"$namespace\" \"$mongopod\" -- mongorestore -u root -p \"$mongo_root_pw\" --gzip --archive=/tmp/mongodump.gz --authenticationDatabase admin" > /dev/null 2>&1; then
        log_failed "mongorestore failed"
        rm -rf "${temp_dir:-}"
        return 1
    fi

    rm -rf "${temp_dir:-}"
    log_ok
}
