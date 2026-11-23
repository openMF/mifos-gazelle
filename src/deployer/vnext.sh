#!/usr/bin/env bash
# vnext.sh -- Mifos Gazelle deployer script for vNext Beta 1 switch 

#------------------------------------------------------------------------------
# Function : deploy_vnext
# Description: Deploys Mojaloop vNext using Kubernetes manifests.
#------------------------------------------------------------------------------
deploy_vnext() {
  log_section "Deploying vNext beta1"

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

  log_step "Copying vNext manifests to working directory"
  mkdir -p "$DEPLOY_WORK_DIR/vnext"
  cp -r "$BASE_DIR/src/deployer/manifests/vnext/." "$DEPLOY_WORK_DIR/vnext/"
  log_ok

  log_step "Updating FQDNs in manifests"
  apply_domain_to_dir "$DEPLOY_WORK_DIR/vnext" "$GAZELLE_DOMAIN" "local"
  log_ok

  log_step "Restoring vNext MongoDB demo data"
  vnext_restore_demo_data "$CONFIG_DIR" "mongodump.gz" "$INFRA_NAMESPACE"
  # log_ok is called inside vnext_restore_demo_data on success

  local last_layer_index=$(( ${#VNEXT_LAYER_DIRS[@]} - 2 ))
  local folder
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

  # The last layers aren't waited on above, and pods can be Running while a service they
  # depend on is still restarting. Check once, at the end and from outside the cluster,
  # that vNext serves its participants, so the first payment after a deploy doesn't fail
  # in account lookup.
  log_step "Checking vNext serves its participants"
  local ready_msg
  if ready_msg=$(vnext_wait_until_ready "$GAZELLE_DOMAIN" "${VNEXT_READY_TIMEOUT:-300}"); then
    log_ok
    log_with_verbose_check "$debug" "$DEBUG" "$ready_msg"
  else
    log_warn "vNext isn't serving participants yet ($ready_msg). Payments may fail until it is."
  fi

  log_banner "vNext Deployed"
}

#------------------------------------------------------------------------------
# Function : vnext_wait_until_ready
# Description: Waits until vNext serves its participants, checked from outside the
#   cluster through the admin UI's ingress (vnextadmin.<domain>), the way an
#   operator or a client would reach it: log in to the authentication service
#   (/auth_n/token) as the admin UI user, list the participants
#   (/_participants/participants), and read each non-hub participant by id. Every
#   one must be active and approved.
# Parameters:
#   $1 - Gazelle domain
#   $2 - timeout in seconds
# Environment: VNEXT_ADMIN_USER / VNEXT_ADMIN_PASSWORD (default: the admin UI's
#   demo login, admin / superMegaPass, as documented in MIFOS-GAZELLE-README.md).
# Output: the last check's result (participant ids, or the reason it failed).
# Returns: 0 when ready, 1 on timeout.
#------------------------------------------------------------------------------
vnext_wait_until_ready() {
  local base="http://vnextadmin.$1" timeout="$2" elapsed=0 interval=10 msg="not checked"
  local user="${VNEXT_ADMIN_USER:-admin}" password="${VNEXT_ADMIN_PASSWORD:-superMegaPass}"

  _vnext_participants_ready() {
    local token ids id p
    token=$(curl -sf --max-time 10 -X POST "$base/auth_n/token" -H 'content-type: application/json' \
      -d "$(jq -n --arg u "$user" --arg p "$password" \
            '{grant_type: "password", client_id: "security-bc-ui", username: $u, password: $p}')" \
      | jq -r '.access_token // empty') || true
    [ -n "$token" ] || { echo "no token from $base/auth_n/token"; return 1; }
    ids=$(curl -sf --max-time 10 -H "authorization: Bearer $token" "$base/_participants/participants" \
      | jq -r '.items[]? | select(.type != "HUB") | .id') || true
    [ -n "$ids" ] || { echo "no participants from $base/_participants/participants"; return 1; }
    for id in $ids; do
      p=$(curl -sf --max-time 10 -H "authorization: Bearer $token" "$base/_participants/participants/$id") \
        || { echo "$id: participant read failed"; return 1; }
      [ "$(jq -r '.isActive and .approved' <<<"$p")" = "true" ] || { echo "$id: not active and approved"; return 1; }
    done
    echo "participants ready: $(echo $ids)"
  }

  while [ "$elapsed" -lt "$timeout" ]; do
    if msg=$(_vnext_participants_ready); then
      echo "$msg"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  echo "$msg"
  return 1
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

    log_ok
}
