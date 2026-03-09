#!/usr/bin/env bash
# mifosx.sh -- Mifos Gazelle deployer script for Mifos X

#------------------------------------------------------------------------------
# Function: teardown_and_recreate_mifosx_namespace
# Description: Removes existing MifosX resources and recreates the namespace.
#------------------------------------------------------------------------------
function teardown_and_recreate_mifosx_namespace() {
    log_step "Removing existing MifosX resources"
    deleteResourcesInNamespaceMatchingPattern "$MIFOSX_NAMESPACE"
    log_ok

    log_step "Creating namespace $MIFOSX_NAMESPACE"
    createNamespace "$MIFOSX_NAMESPACE"
    log_ok
}

#------------------------------------------------------------------------------
# Function: patch_mifosx_fqdns
# Description: Rewrites domain placeholders in the web-app manifests with the
#              configured GAZELLE_DOMAIN.
#------------------------------------------------------------------------------
function patch_mifosx_fqdns() {
    log_step "Updating FQDNs in manifests"
    local fqdn_files=(
        "$MIFOSX_MANIFESTS_DIR/web-app-deployment.yaml"
        "$MIFOSX_MANIFESTS_DIR/web-app-ingress.yaml"
    )
    for f in "${fqdn_files[@]}"; do
        update_fqdn "$f" "mifos.gazelle.test"      "$GAZELLE_DOMAIN"
        update_fqdn "$f" "mifos.gazelle.localhost"  "$GAZELLE_DOMAIN"
    done
    log_ok
}

#------------------------------------------------------------------------------
# Function: deploy_mifosx_from_yaml
# Description: Deploys MifosX (Fineract + web app) using Kubernetes manifests from a specified directory.
# Parameters:
#   $1 - Directory containing the Kubernetes manifests for MifosX deployment.
#   $2 - (Optional) Timeout in seconds to wait for Payment Hub pods to be ready. Default is 600 seconds.
#------------------------------------------------------------------------------
function deploy_mifosx_from_yaml() {
    local manifests_dir="$1"
    local timeout_secs="${2:-600}"  # Default timeout of 10 minutes if not specified

    log_section "Deploying MifosX"

    if is_app_running "$MIFOSX_NAMESPACE"; then
      if [[ "$redeploy" == "false" ]]; then
        log_info "MifosX already deployed — skipping."
        return
      fi
    fi

    run_as_user "kubectl wait --for=condition=ready pod --all -n $PH_NAMESPACE --timeout=${timeout_secs}s" > /dev/null 2>&1

    teardown_and_recreate_mifosx_namespace

    cloneRepo "$MIFOSX_BRANCH" "$MIFOSX_REPO_LINK" "$APPS_DIR" "$MIFOSX_REPO_DIR"

    patch_mifosx_fqdns

    log_step "Restoring MifosX database dump"
    run_as_user "$UTILS_DIR/dump-restore-fineract-db.sh -r" > /dev/null
    log_ok

    log_step "Applying manifests"
    applyKubeManifests "$manifests_dir" "$MIFOSX_NAMESPACE"
    log_ok

    log_banner "MifosX Deployed"
}

#------------------------------------------------------------------------------
# Function: poll_fineract_tenant
# Description: Polls a single Fineract tenant until both schema migration (HTTP 200
#              on /clients) and seed-data migration (non-empty /paymenttypes) confirm
#              the tenant is fully initialised, or the timeout is reached.
# Parameters:
#   $1 - Tenant name (e.g. "greenbank")
#   $2 - Base URL  (e.g. "https://mifos.example.test/fineract-provider/api/v1")
#   $3 - Authorization header value
#   $4 - Timeout in seconds
#   $5 - Retry interval in seconds
# Returns: 0 if ready, 1 on timeout
#------------------------------------------------------------------------------
function poll_fineract_tenant() {
    local tenant="$1"
    local base_url="$2"
    local auth="$3"
    local timeout="$4"
    local retry_interval="$5"

    local start_time
    start_time=$(date +%s)
    local elapsed=0

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
                return 0
            else
                logWithVerboseCheck "$debug" "$DEBUG" "Tenant '${tenant}' schema ready, seed data pending (${elapsed}s/${timeout}s)"
            fi
        else
            logWithVerboseCheck "$debug" "$DEBUG" "Tenant '${tenant}' schema not ready — HTTP ${clients_code:-000} (${elapsed}s/${timeout}s)"
        fi

        sleep "$retry_interval"
        elapsed=$(( $(date +%s) - start_time ))
    done

    log_failed "Fineract tenant '${tenant}' not ready after ${timeout}s"
    return 1
}

#------------------------------------------------------------------------------
# Function: wait_for_fineract_api_ready
# Description: Polls two Fineract endpoints per tenant until both confirm the
#              tenant is fully initialised:
#                1. /clients       → HTTP 200  (schema migration complete)
#                2. /paymenttypes  → non-empty array (seed-data migration complete)
#              Checking only /clients is insufficient: it returns 200 as soon as
#              the DDL migration finishes, but Fineract's DML seed phase (payment
#              types, currencies, offices) runs afterwards.  Savings-product and
#              client creation fail with 4xx until that seed phase completes.
# Parameters: None (uses GAZELLE_DOMAIN, MIFOS_USER, MIFOS_PASSWORD env vars)
# Returns:    0 if all tenants ready, 1 on timeout
#------------------------------------------------------------------------------
function wait_for_fineract_api_ready {
  local tenants=("greenbank" "bluebank" "redbank")
  local base_url="https://mifos.${GAZELLE_DOMAIN}/fineract-provider/api/v1"
  local auth
  auth="Basic $(printf '%s:%s' "${MIFOS_USER:-mifos}" "${MIFOS_PASSWORD:-password}" | base64 -w 0)"
  local timeout=300
  local retry_interval=10

  # log_info (not log_step) used here: poll_fineract_tenant emits verbose output
  # during the wait, which would break a log_step/log_ok inline pairing.
  log_info "Waiting for Fineract tenant APIs (schema + seed data)"

  for tenant in "${tenants[@]}"; do
    log_step "  Tenant: ${tenant}"
    poll_fineract_tenant "$tenant" "$base_url" "$auth" "$timeout" "$retry_interval" || return 1
    log_ok
  done

  return 0
}

#------------------------------------------------------------------------------
# Function: wait_for_apps_running
# Description: Polls until both vnext and mifosx are running, or the timeout expires.
# Parameters:
#   $1 - Timeout in seconds
#   $2 - Recheck interval in seconds
# Returns: 0 if both apps running, 1 on timeout
#------------------------------------------------------------------------------
function wait_for_apps_running() {
    local timeout="$1"
    local recheck_time="$2"
    local start_time
    start_time=$(date +%s)
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        if is_app_running "vnext" && is_app_running "mifosx"; then
            return 0
        fi

        elapsed=$(( $(date +%s) - start_time ))
        if [[ $elapsed -lt $timeout ]]; then
            logWithVerboseCheck "$debug" "$DEBUG" "vNext or MifosX not running — retrying in ${recheck_time}s (${elapsed}s/${timeout}s)"
            sleep "$recheck_time"
            elapsed=$(( $(date +%s) - start_time ))
        fi
    done

    return 1
}

#------------------------------------------------------------------------------
# Function: generate_mifosx_and_vnext_data
# Description: Generates MifosX clients and accounts & registers associations with vNext Oracle.
# Parameters: None
#------------------------------------------------------------------------------
function generate_mifosx_and_vnext_data {
  local timeout=300  # 5 minutes in seconds
  local recheck_time=30  # 30 seconds

  if ! wait_for_apps_running "$timeout" "$recheck_time"; then
    log_warn "vNext or MifosX did not start within ${timeout}s — skipping data generation"
    return 1
  fi

  if ! wait_for_fineract_api_ready; then
    log_error "Fineract API not ready — aborting data generation"
    return 1
  fi

  log_step "Generating MifosX clients and registering vNext Oracle associations"
  local quoted_cfg
  printf -v quoted_cfg '%q' "$CONFIG_FILE_PATH"
  run_as_user "$RUN_DIR/src/utils/data-loading/generate-mifos-vnext-data.py -c $quoted_cfg"

  if [[ "$?" -ne 0 ]]; then
    log_failed "Data generation failed"
    log_error "Run: $RUN_DIR/src/utils/data-loading/generate-mifos-vnext-data.py -c $CONFIG_FILE_PATH"
    return 1
  fi
  log_ok
  generate_sample_csvs
}
