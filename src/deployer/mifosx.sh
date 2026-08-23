#!/usr/bin/env bash
# mifosx.sh -- Mifos Gazelle deployer script for Mifos X 

#------------------------------------------------------------------------------
# Function: check_mifosx_images
# Description: Warns about images referenced by the MifosX manifests that cannot be
#              found in a registry. Some MifosX modules have no published image and
#              are built from source (see docs/MIFOSX.md), so a missing image would
#              otherwise surface only as an ImagePullBackOff after a long timeout.
#              Advisory only — never blocks the deploy.
# Parameters:
#   $1 - Directory containing the MifosX manifests.
#------------------------------------------------------------------------------
check_mifosx_images() {
    local manifests_dir="$1"
    local image missing=()

    # No docker (e.g. deploying to a remote cluster from a machine without it) —
    # nothing to check against, so say nothing.
    command -v docker > /dev/null 2>&1 || return 0

    log_step "Checking module images are available"

    # The awk below matches both "image: x" and the list-item form "- image: x".
    # A commented "#image: x" does not match, so disabled pins are ignored.
    while IFS= read -r image; do
        [ -z "$image" ] && continue
        if ! docker manifest inspect "$image" > /dev/null 2>&1; then
            missing+=("$image")
        fi
    done < <(awk '/^[[:space:]]*-?[[:space:]]*image:[[:space:]]*/ {
                      sub(/^[[:space:]]*-?[[:space:]]*image:[[:space:]]*/, "")
                      gsub(/["'"'"']/, "")
                      print
                  }' "$manifests_dir"/*.yaml | sort -u)

    if [ ${#missing[@]} -eq 0 ]; then
        log_ok
        return 0
    fi

    log_skipped
    log_warn "Could not find ${#missing[@]} image(s) in a registry:"
    for image in "${missing[@]}"; do
        echo "             $image"
    done
    log_warn "If a module image has not been published yet, build and push it with"
    log_warn "src/utils/build-and-import-image.sh — see docs/MIFOSX.md and docs/BUILDING-IMAGES.md."
    log_warn "This check is advisory (a rate-limited or private registry looks the same); continuing."
}

#------------------------------------------------------------------------------
# Function: deploy_mifosx_from_yaml
# Description: Deploys MifosX (Fineract + web app) using Kubernetes manifests from a specified directory.
# Parameters:
#   $1 - Directory containing the Kubernetes manifests for MifosX deployment.
#   $2 - (Optional) Timeout in seconds to wait for the fineract-server pod to be ready. Default is 600 seconds.
#------------------------------------------------------------------------------
deploy_mifosx_from_yaml() {
    local manifests_dir="$1"
    local timeout_secs="${2:-600}"

    log_section "Deploying MifosX"

    if is_app_running "$MIFOSX_NAMESPACE"; then
      if [[ "$redeploy" == "false" ]]; then
        echo "    MifosX already deployed — skipping."
        return
      fi
    fi

    kubectl wait --for=condition=ready pod --all -n "$PH_NAMESPACE" --timeout=600s > /dev/null 2>&1

    log_step "Removing existing MifosX resources"
    delete_resources_in_namespace_matching_pattern "$MIFOSX_NAMESPACE"
    log_ok

    log_step "Creating namespace $MIFOSX_NAMESPACE"
    create_namespace "$MIFOSX_NAMESPACE"
    log_ok

    log_step "Copying MifosX manifests to working directory"
    mkdir -p "$DEPLOY_WORK_DIR/mifosx"
    cp -r "$BASE_DIR/src/deployer/manifests/mifosx/." "$DEPLOY_WORK_DIR/mifosx/"
    log_ok

    log_step "Updating FQDNs in manifests"
    apply_domain_to_file "$MIFOSX_MANIFESTS_DIR/web-app-deployment.yaml" "$GAZELLE_DOMAIN"
    apply_domain_to_file "$MIFOSX_MANIFESTS_DIR/web-app-ingress.yaml" "$GAZELLE_DOMAIN"
    apply_domain_to_file "$MIFOSX_MANIFESTS_DIR/mifos-workflow-ingress.yaml" "$GAZELLE_DOMAIN"
    apply_domain_to_file "$MIFOSX_MANIFESTS_DIR/credit-bureau-ingress.yaml" "$GAZELLE_DOMAIN"
    apply_domain_to_file "$MIFOSX_MANIFESTS_DIR/loan-module-ingress.yaml" "$GAZELLE_DOMAIN"
    apply_domain_to_file "$MIFOSX_MANIFESTS_DIR/message-gateway-ingress.yaml" "$GAZELLE_DOMAIN"
    log_ok

    check_mifosx_images "$MIFOSX_MANIFESTS_DIR"

    log_step "Restoring MifosX database dump"
    "$DATA_LOADING_DIR/dump-restore-fineract-db.sh" -r > /dev/null
    log_ok

    log_step "Applying manifests"
    apply_kube_manifests "$manifests_dir" "$MIFOSX_NAMESPACE"
    log_ok

    wait_for_fineract_api_ready || return 1

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
wait_for_fineract_api_ready() {
  IFS=' ' read -ra tenants <<< "${FINERACT_TENANTS:-greenbank bluebank redbank}"
  local base_url="https://mifos.${GAZELLE_DOMAIN}/fineract-provider/api/v1"
  local auth
  auth="Basic $(printf '%s:%s' "${FINERACT_USERNAME:-mifos}" "${FINERACT_PASSWORD:-password}" | base64)"
  local timeout=${startup_timeout:-600}
  local retry_interval=10
  local global_start
  global_start=$(date +%s)

  log_step "Waiting for Fineract tenant APIs (timeout=${timeout}s)"

  for tenant in "${tenants[@]}"; do
    local ready=false

    while true; do
      local elapsed=$(( $(date +%s) - global_start ))
      if [[ $elapsed -ge $timeout ]]; then
        log_failed "Fineract tenant '${tenant}' not ready after ${timeout}s"
        return 1
      fi

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
          log_with_verbose_check "$debug" "$DEBUG" "Tenant '${tenant}' ready (${elapsed}s elapsed)"
          ready=true
          break
        else
          log_with_verbose_check "$debug" "$DEBUG" "Tenant '${tenant}' schema ready, seed data pending (${elapsed}s/${timeout}s)"
        fi
      else
        log_with_verbose_check "$debug" "$DEBUG" "Tenant '${tenant}' schema not ready — HTTP ${clients_code:-000} (${elapsed}s/${timeout}s)"
      fi

      sleep "$retry_interval"
    done
  done

  log_ok
  return 0
}

#------------------------------------------------------------------------------
# Function : generate_mifosx_and_vnext_data
# Description: Generates MifosX clients and accounts & registers associations with vNext Oracle.
# Parameters: None
#------------------------------------------------------------------------------
generate_mifosx_and_vnext_data() {
  local timeout=${startup_timeout:-600}
  local recheck_time=30
  local start_time
  start_time=$(date +%s)
  local elapsed=0
  local retry_cmd="$RUN_DIR/run.sh -m deploy -a setup-data -f \"$CONFIG_FILE_PATH\""

  while [[ $elapsed -lt $timeout ]]; do
    local result_vnext result_mifosx
    is_app_running "vnext"
    result_vnext=$?
    is_app_running "mifosx"
    result_mifosx=$?

    if [[ $result_vnext -eq 0 ]] && [[ $result_mifosx -eq 0 ]]; then
      if ! wait_for_fineract_api_ready; then
        log_error "Fineract API not ready — aborting data generation"
        log_warn "Re-run when the cluster is ready:  $retry_cmd"
        return 1
      fi

      log_step "Generating MifosX clients and vNext Oracle data"
      echo
      "$PYTHON3" "$RUN_DIR/src/utils/data-loading/generate-mifos-vnext-data.py" -c "$CONFIG_FILE_PATH" 2>&1
      local data_gen_exit=$?

      if [[ $data_gen_exit -ne 0 ]]; then
        log_failed "Data generation failed"
        log_warn "Re-run when the cluster is ready:  $retry_cmd"
        return 1
      fi
      log_ok
      generate_sample_csvs
      return 0
    else
      elapsed=$(( $(date +%s) - start_time ))
      if [[ $elapsed -lt $timeout ]]; then
        log_with_verbose_check "$debug" "$DEBUG" "vNext or MifosX not running — retrying in ${recheck_time}s (${elapsed}s/${timeout}s)"
        sleep $recheck_time
        elapsed=$(( $(date +%s) - start_time ))
      fi
    fi
  done

  log_warn "vNext or MifosX did not start within ${timeout}s — data generation skipped"
  log_warn "Re-run when the cluster is ready:  $retry_cmd"
  return 1
}
