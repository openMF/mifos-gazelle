#!/usr/bin/env bash
# mifosx.sh -- Mifos Gazelle deployer script for Mifos X 

#------------------------------------------------------------------------------
# Function: DeployMifosXfromYaml
# Description: Deploys MifosX (Fineract + web app) using Kubernetes manifests from a specified directory.
# Parameters:
#   $1 - Directory containing the Kubernetes manifests for MifosX deployment.
#   $2 - (Optional) Timeout in seconds to wait for the fineract-server pod to be ready. Default is 600 seconds.
#------------------------------------------------------------------------------
function DeployMifosXfromYaml() {
    manifests_dir=$1
    timeout_secs=${2:-600}  # Default timeout of 10 minutes if not specified

    log_section "Deploying MifosX"

    if is_app_running "$MIFOSX_NAMESPACE"; then
      if [[ "$redeploy" == "false" ]]; then
        echo "    MifosX already deployed — skipping."
        return
      fi
    fi

    run_as_user "kubectl wait --for=condition=ready pod --all -n $PH_NAMESPACE --timeout=600s" > /dev/null 2>&1

    log_step "Removing existing MifosX resources"
    deleteResourcesInNamespaceMatchingPattern "$MIFOSX_NAMESPACE"
    log_ok

    log_step "Creating namespace $MIFOSX_NAMESPACE"
    createNamespace "$MIFOSX_NAMESPACE"
    log_ok

    cloneRepo "$MIFOSX_BRANCH" "$MIFOSX_REPO_LINK" "$APPS_DIR" "$MIFOSX_REPO_DIR"

    log_step "Updating FQDNs in manifests"
    update_fqdn "$MIFOSX_MANIFESTS_DIR/web-app-deployment.yaml" "mifos.gazelle.test" "$GAZELLE_DOMAIN"
    update_fqdn "$MIFOSX_MANIFESTS_DIR/web-app-ingress.yaml" "mifos.gazelle.test" "$GAZELLE_DOMAIN"
    update_fqdn "$MIFOSX_MANIFESTS_DIR/web-app-deployment.yaml" "mifos.gazelle.localhost" "$GAZELLE_DOMAIN"
    update_fqdn "$MIFOSX_MANIFESTS_DIR/web-app-ingress.yaml" "mifos.gazelle.localhost" "$GAZELLE_DOMAIN"
    log_ok

    log_step "Restoring MifosX database dump"
    run_as_user "$UTILS_DIR/dump-restore-fineract-db.sh -r" > /dev/null
    log_ok

    log_step "Applying manifests"
    applyKubeManifests "$manifests_dir" "$MIFOSX_NAMESPACE"
    log_ok

    log_banner "MifosX Deployed"
}

#------------------------------------------------------------------------------
# Function : wait_for_fineract_api_ready
# Description: Polls two Fineract endpoints per tenant until both confirm the
#              tenant is fully initialised:
#                1. /clients       → HTTP 200  (schema migration complete)
#                2. /paymenttypes  → non-empty array (seed-data migration complete)
#              Checking only /clients is insufficient: it returns 200 as soon as
#              the DDL migration finishes, but Fineract's DML seed phase (payment
#              types, currencies, offices) runs afterwards.  Savings-product and
#              client creation fail with 4xx until that seed phase completes.
# Parameters: None (uses GAZELLE_DOMAIN)
# Returns:    0 if all tenants ready, 1 on timeout
#------------------------------------------------------------------------------
function wait_for_fineract_api_ready {
  local tenants=("greenbank" "bluebank" "redbank")
  local base_url="https://mifos.${GAZELLE_DOMAIN}/fineract-provider/api/v1"
  local auth="Basic bWlmb3M6cGFzc3dvcmQ="   # mifos:password
  local timeout=300
  local retry_interval=10

  log_step "Waiting for Fineract tenant APIs (schema + seed data)"

  for tenant in "${tenants[@]}"; do
    local start_time
    start_time=$(date +%s)
    local elapsed=0
    local ready=false

    while [[ $elapsed -lt $timeout ]]; do
      local clients_code
      clients_code=$(curl -sk -o /dev/null -w "%{http_code}" \
        -H "Authorization: ${auth}" \
        -H "Fineract-Platform-TenantId: ${tenant}" \
        --max-time 10 \
        "${base_url}/clients" 2>/dev/null)

      if [[ "$clients_code" == "200" ]]; then
        local paymenttypes_body
        paymenttypes_body=$(curl -sk \
          -H "Authorization: ${auth}" \
          -H "Fineract-Platform-TenantId: ${tenant}" \
          --max-time 10 \
          "${base_url}/paymenttypes" 2>/dev/null)

        if [[ "$paymenttypes_body" =~ ^\[ && "$paymenttypes_body" != "[]" ]]; then
          logWithVerboseCheck "$debug" "$DEBUG" "Tenant '${tenant}' ready (${elapsed}s)"
          ready=true
          break
        else
          logWithVerboseCheck "$debug" "$DEBUG" "Tenant '${tenant}' schema ready, seed data pending (${elapsed}s/${timeout}s)"
        fi
      else
        logWithVerboseCheck "$debug" "$DEBUG" "Tenant '${tenant}' schema not ready — HTTP ${clients_code:-000} (${elapsed}s/${timeout}s)"
      fi

      sleep $retry_interval
      elapsed=$(( $(date +%s) - start_time ))
    done

    if [[ "$ready" != "true" ]]; then
      log_failed "Fineract tenant '${tenant}' not ready after ${timeout}s"
      return 1
    fi
  done

  log_ok
  return 0
}

#------------------------------------------------------------------------------
# Function : generateMifosXandVNextData
# Description: Generates MifosX clients and accounts & registers associations with vNext Oracle.
# Parameters: None
#------------------------------------------------------------------------------
function generateMifosXandVNextData {  
  local timeout=300  # 5 minutes in seconds
  local recheck_time=30  # 30 seconds
  local start_time=$(date +%s)
  local elapsed=0
  
  while [[ $elapsed -lt $timeout ]]; do
    is_app_running "vnext"
    result_vnext=$?
    is_app_running "mifosx"
    result_mifosx=$?
    
    if [[ $result_vnext -eq 0 ]] && [[ $result_mifosx -eq 0 ]]; then
      if ! wait_for_fineract_api_ready; then
        log_error "Fineract API not ready — aborting data generation"
        return 1
      fi

      log_step "Generating MifosX clients and registering vNext Oracle associations"
      results=$(run_as_user "$RUN_DIR/src/utils/data-loading/generate-mifos-vnext-data.py -c \"$CONFIG_FILE_PATH\" ")

      if [[ "$?" -ne 0 ]]; then
        log_failed "Data generation failed"
        log_error "Run: $RUN_DIR/src/utils/data-loading/generate-mifos-vnext-data.py -c $CONFIG_FILE_PATH"
        return 1
      fi
      log_ok
      generate_sample_csvs
      return 0
    else
      elapsed=$(( $(date +%s) - start_time ))
      if [[ $elapsed -lt $timeout ]]; then
        logWithVerboseCheck "$debug" "$DEBUG" "vNext or MifosX not running — retrying in ${recheck_time}s (${elapsed}s/${timeout}s)"
        sleep $recheck_time
        elapsed=$(( $(date +%s) - start_time ))
      fi
    fi
  done

  log_warn "vNext or MifosX did not start within ${timeout}s — skipping data generation"
  return 1
}
