#!/usr/bin/env bash
# deployer.sh -- the main Mifos Gazelle deployer script

source "$RUN_DIR/src/deployer/core.sh" || { echo "FATAL: Could not source core.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/deployer/vnext.sh" || { echo "FATAL: Could not source vnext.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/deployer/mifosx.sh" || { echo "FATAL: Could not source mifosx.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/deployer/paymenthub.sh" || { echo "FATAL: Could not source paymenthub.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/deployer/mastercard.sh" || { echo "FATAL: Could not source mastercard.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/deployer/openg2p.sh" || { echo "FATAL: Could not source openg2p.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/deployer/openspp.sh" || { echo "FATAL: Could not source openspp.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/utils/helpers.sh" || { echo "FATAL: Could not source helpers.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }

#------------------------------------------------------------
# Description : Deletes K8s namespaces matching a regex pattern.
# Usage : delete_resources_in_namespace_matching_pattern <regex_pattern>
# Example: delete_resources_in_namespace_matching_pattern "app-.*"
#------------------------------------------------------------
delete_resources_in_namespace_matching_pattern() {
    local pattern="$1"
    if [ -z "$pattern" ]; then
        log_error "delete_resources_in_namespace_matching_pattern: pattern argument required"
        exit 1
    fi
        
    # Get all namespaces and filter them locally
    local all_namespaces_output matching_namespaces
    all_namespaces_output=$(kubectl get namespaces -o name 2>&1)
    check_command_execution $? "kubectl get namespaces -o name"
    
    # Filter the output for namespaces matching the pattern, stripping the "namespace/" prefix
    # grep returns 1 if no matches, but we want to continue, hence || true
    matching_namespaces=$(echo "$all_namespaces_output" | grep -E "$pattern" | sed 's/^namespace\///' || true)

    if [ -z "$matching_namespaces" ]; then
        return 0
    fi
    
    local exit_code=0
    # Read the namespaces line by line
    while read -r namespace; do
        # Skip empty lines and 'default' namespace
        if [ -z "$namespace" ] || [[ "$namespace" == "default" ]]; then
            continue
        fi

        # Delete the namespace (this removes all resources within it)
        if ! kubectl delete ns "$namespace" --ignore-not-found=true >> /dev/null 2>&1 ; then
            log_failed "Failed to delete namespace $namespace"
            exit_code=1
        fi
    done <<< "$matching_namespaces"
    
    return $exit_code
}

#------------------------------------------------------------
# Description : Deploys a Helm chart from a local dir to a K8s NS.
# Usage : deploy_helm_chart_from_dir <dir> <ns> <release> [values_file]
# Example: deploy_helm_chart_from_dir ./chart infra infra-rls values.yaml
#------------------------------------------------------------
deploy_helm_chart_from_dir() {
  if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "Usage: deploy_helm_chart_from_dir <chart_dir> <namespace> <release_name> [values_file]"
    return 1
  fi

  local chart_dir="$1"
  local namespace="$2"
  local release_name="$3"
  local values_file="$4"

  if [ ! -d "$chart_dir" ]; then
    log_error "Chart directory '$chart_dir' does not exist."
    return 1
  fi

  # Build helm command — upgrade --install is idempotent: works whether the
  # release exists or not, avoiding "already exists" failures on re-runs.
  local helm_cmd=(helm upgrade --install --wait --timeout "${startup_timeout}s" "$release_name" "$chart_dir" -n "$namespace")
  if [ -n "$values_file" ]; then
      helm_cmd+=(-f "$values_file")
  fi

  # Run helm and capture the exit code WITHOUT calling exit here.
  # deploy_infrastructure wraps this call with >/dev/null 2>&1 in non-debug
  # mode to suppress verbose output.  Any exit called inside that suppressed
  # block would terminate the whole script silently — returning lets the
  # caller's check_command_execution show a visible error instead.
  "${helm_cmd[@]}"
  local helm_exit=$?
  if [[ $helm_exit -ne 0 ]]; then
    return $helm_exit
  fi

  if is_app_running "$namespace"; then
    return 0
  else
    log_error "Helm chart deployment failed in namespace '$namespace'."
    return 1
  fi
}

#------------------------------------------------------------
# Description : Creates a K8s namespace if it doesn't exist.
#               Configures Docker Hub authentication if credentials available.
# Usage : create_namespace <namespace>
# Example: create_namespace mifosx-ns
#------------------------------------------------------------
create_namespace() {
  local namespace=$1

  # If namespace is in Terminating state, wait for natural deletion then force-clear
  # finalizers if it's stuck (common when operator was stopped before CR finalizers
  # were removed, or when a previous deploy was interrupted mid-teardown).
  if kubectl get namespace "$namespace" > /dev/null 2>&1; then
    local phase
    phase=$(kubectl get namespace "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$phase" == "Terminating" ]]; then
      kubectl wait --for=delete namespace/"$namespace" --timeout=60s > /dev/null 2>&1 || true
      # If still stuck, force-remove namespace-level finalizers so Kubernetes can proceed
      if kubectl get namespace "$namespace" > /dev/null 2>&1; then
        kubectl patch namespace "$namespace" --type=merge \
          -p '{"spec":{"finalizers":null}}' > /dev/null 2>&1 || true
        kubectl wait --for=delete namespace/"$namespace" --timeout=60s > /dev/null 2>&1 || true
      fi
    fi
  fi

  # Create namespace if it still doesn't exist
  if ! kubectl get namespace "$namespace" > /dev/null 2>&1; then
    kubectl create namespace "$namespace" > /dev/null 2>&1
    check_command_execution $? "kubectl create namespace $namespace"
  fi

  # Configure Docker Hub authentication for this namespace
  # Script exits silently if DOCKERHUB_USERNAME/PASSWORD not set
  if [[ -f "$UTILS_DIR/k3s-docker-login.sh" ]]; then
    if [ "$debug" = true ]; then
      DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME:-}" DOCKERHUB_PASSWORD="${DOCKERHUB_PASSWORD:-}" DOCKERHUB_EMAIL="${DOCKERHUB_EMAIL:-}" \
        "$UTILS_DIR/k3s-docker-login.sh" "$namespace"
    else
      DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME:-}" DOCKERHUB_PASSWORD="${DOCKERHUB_PASSWORD:-}" DOCKERHUB_EMAIL="${DOCKERHUB_EMAIL:-}" \
        "$UTILS_DIR/k3s-docker-login.sh" "$namespace" > /dev/null 2>&1
    fi
  fi
}

#------------------------------------------------------------
# Description : Deploys infrastructure chart via Helm.
# Usage : deploy_infrastructure [redeploy_bool]
# Example: deploy_infrastructure true
#------------------------------------------------------------
deploy_infrastructure() {
  local redeploy="${1:-false}"

  if is_app_running "$INFRA_NAMESPACE" && [[ "$redeploy" == "false" ]]; then
    return 0
  fi

  log_section "Deploying infrastructure"

  if is_app_running "$INFRA_NAMESPACE"; then
    log_step "Removing existing infrastructure"
    delete_resources_in_namespace_matching_pattern "$INFRA_NAMESPACE"
    log_ok
  fi

  log_step "Creating namespace $INFRA_NAMESPACE"
  create_namespace "$INFRA_NAMESPACE"
  check_command_execution $? "create_namespace $INFRA_NAMESPACE"
  log_ok

  log_step "Updating FQDNs"
  apply_domain_to_file "$INFRA_CHART_DIR/values.yaml" "$GAZELLE_DOMAIN"
  log_ok

  ensure_helm_dependencies "$INFRA_CHART_DIR"

  log_step "Helm chart (infra)"
  if [ "$debug" = true ]; then
    deploy_helm_chart_from_dir "$RUN_DIR/src/deployer/helm/infra" "$INFRA_NAMESPACE" "$INFRA_RELEASE_NAME"
  else
    deploy_helm_chart_from_dir "$RUN_DIR/src/deployer/helm/infra" "$INFRA_NAMESPACE" "$INFRA_RELEASE_NAME" >> /dev/null 2>&1
  fi
  check_command_execution $? "deploy_helm_chart_from_dir infra"
  log_ok

  log_banner "Infrastructure Deployed"
}

#------------------------------------------------------------
# Description : Applies K8s YAML manifests from a directory.
# Usage : apply_kube_manifests <directory> <namespace>
# Example: apply_kube_manifests ./k8s-files mifosx-ns
#------------------------------------------------------------
apply_kube_manifests() {
    if [ "$#" -ne 2 ]; then
        echo "Usage: apply_kube_manifests <directory> <namespace>"
        return 1
    fi
    
    local directory="$1"
    local namespace="$2"

    if [ ! -d "$directory" ]; then
        log_error "Directory '$directory' not found."
        return 1
    fi

    # Apply persistence-related manifests first
    for file in "$directory"/*persistence*.yaml; do
      if [ -f "$file" ]; then
        kubectl apply -f "$file" -n "$namespace" >> /dev/null 2>&1
        check_command_execution $? "kubectl apply -f $file -n $namespace"
      fi
  done

    # Apply other manifests
    for file in "$directory"/*.yaml; do
      if [[ "$file" != *persistence*.yaml && -f "$file" ]]; then
        kubectl apply -f "$file" -n "$namespace" >> /dev/null 2>&1
        check_command_execution $? "kubectl apply -f $file -n $namespace"
      fi
    done
}

#------------------------------------------------------------
# Description : Prints cleanup end message .
#------------------------------------------------------------
print_cleanup_end_message() {
  log_banner "Cleanup Complete"
  echo
}

#------------------------------------------------------------
# Description : Prints final deployment status and access info.
# Usage : print_deployment_end_message
# Example: print_deployment_end_message
#------------------------------------------------------------
print_deployment_end_message() {
  local data_gen_failed="${1:-false}"

  log_banner "Mifos Gazelle Ready"
  echo
  echo "  MifosX:        https://mifos.${GAZELLE_DOMAIN}"
  echo "  vNext Admin:   http://vnextadmin.${GAZELLE_DOMAIN}"
  echo "  Ops Web:       http://ops.${GAZELLE_DOMAIN}"
  echo "  Zeebe Operate: http://zeebe-operate.${GAZELLE_DOMAIN}"
  echo
  echo "  kubectl get pods -A"
  echo
  if [[ "$data_gen_failed" == "true" ]]; then
    log_warn "Data generation did not complete — test payments and batch submissions will not work."
    log_warn "Once the cluster is stable, re-run:  $RUN_DIR/run.sh -m deploy -a setup-data -f \"$CONFIG_FILE_PATH\""
    echo
  fi
}

#------------------------------------------------------------
# Description : Deletes all or specific applications by namespace.
# Usage : delete_apps <ignored> <"app1 app2"|all>
# Example: delete_apps _ "mifosx vnext"
#------------------------------------------------------------
delete_apps() {
  local appsToDelete="$1"

  log_section "Removing applications"
  for app in $appsToDelete; do
    case "$app" in
      "vnext")
        log_step "Removing vNext"
        delete_resources_in_namespace_matching_pattern "$VNEXT_NAMESPACE"
        log_ok
        ;;
      "mifosx")
        log_step "Removing MifosX"
        delete_resources_in_namespace_matching_pattern "$MIFOSX_NAMESPACE"
        log_ok
        ;;
      "paymenthub")
        log_step "Removing Payment Hub EE"
        clean_phee
        log_ok
        ;;
      "infra")
        log_step "Removing infrastructure"
        delete_resources_in_namespace_matching_pattern "$INFRA_NAMESPACE"
        log_ok
        ;;
      "mastercard-demo")
        log_step "Removing Mastercard demo"
        cleanup
        log_ok
        ;;
      "openg2p")
        clean_openg2p
        ;;
      "openspp")
        log_step "Removing OpenSPP"
        cleanup_openspp
        log_ok
        ;;
      *)
        log_error "Invalid app '$app' for deletion. This should have been caught by validate_inputs."
        show_usage
        exit 1
        ;;
    esac
  done

  print_cleanup_end_message
}

#------------------------------------------------------------
# Description : Orchestrates deployment of apps (infra, vnext, etc.).
# Usage : deploy_apps <"app1 app2"... > [redeploy]
# Example: deploy_apps _ "vnext mifosx" true
#------------------------------------------------------------
deploy_apps() {
  local appsToDeploy="$1"
  local redeploy="${2:-false}"
  local data_gen_failed=false

  log_with_verbose_check "$debug" "$DEBUG" "Apps to deploy: $appsToDeploy (redeploy=$redeploy)"

  # Ensure infra is up before any DPG deployment. The idempotency guard inside
  # deploy_infrastructure makes this a no-op if infra is already running.
  # Skip when infra itself is being deployed — its case arm handles that below.
  # Also skip for an OpenSPP-only deploy: OpenSPP brings its own PostGIS DB and does not use
  # the shared infra chart.
  if [[ "$appsToDeploy" != *"infra"* && "$appsToDeploy" != "openspp" ]]; then
    deploy_infrastructure "false"
  fi

  for app in $appsToDeploy; do
    case "$app" in
      "infra")
        deploy_infrastructure "$redeploy"
        ;;
      "vnext")
        deploy_vnext
        ;;
      "mifosx")
        deploy_mifosx_from_yaml "$MIFOSX_MANIFESTS_DIR"
        if ! generate_mifosx_and_vnext_data; then
          data_gen_failed=true
        fi
        ;;
      "setup-data")
        if ! generate_mifosx_and_vnext_data; then
          data_gen_failed=true
        fi
        ;;
      "paymenthub")
        deploy_ph
        ;;
      "mastercard-demo")
        if [[ "$redeploy" == "true" ]]; then
          delete_apps "mastercard-demo"
        fi
        if ! kubectl get namespace "$PH_NAMESPACE" &> /dev/null; then
          log_error "Payment Hub namespace not found. Deploy paymenthub first: ./run.sh -a paymenthub"
          exit 1
        fi
        log_with_verbose_check "$debug" "$DEBUG" "MASTERCARD_CBS_HOME=$MASTERCARD_CBS_HOME"
        deploy_mastercard
        ;;
      "openg2p")
        deploy_openg2p
        ;;
      "openspp")
        if [[ "$redeploy" == "true" ]]; then
          cleanup_openspp
        fi
        deploy_openspp
        ;;
      *)
        log_error "Unknown application '$app'. This should have been caught by validation."
        show_usage
        exit 1
        ;;
    esac
  done

  save_applied_domain
  print_deployment_end_message "$data_gen_failed"
}

#------------------------------------------------------------
# Description : Checks all pods in a namespace are Running/Completed.
#               Calls k8s-error-summary.py on failure.
# Usage : check_pods_ready <namespace>
# Returns : 0 = all ready, 1 = something not ready
#------------------------------------------------------------
check_pods_ready() {
  local namespace="$1"
  local kubectl_output
  local kubectl_exit_code

  kubectl_output=$(run_as_user "kubectl get pods -n \"$namespace\" --no-headers 2>/dev/null")
  kubectl_exit_code=$?

  if [[ $kubectl_exit_code -ne 0 ]]; then
    log_error "Namespace '$namespace': kubectl failed (cluster down or namespace missing)"
    if [[ -f "$UTILS_DIR/k8s-error-summary.py" ]]; then
      python3 "$UTILS_DIR/k8s-error-summary.py" "$namespace" || true
    fi
    return 1
  fi

  local not_ready
  not_ready=$(echo "$kubectl_output" | grep -v -E "Running|Completed|Succeeded" | wc -l)

  if [[ "$not_ready" -gt 0 ]]; then
    log_error "Namespace '$namespace': $not_ready pod(s) not Running/Completed:"
    echo "$kubectl_output"
    if [[ -f "$UTILS_DIR/k8s-error-summary.py" ]]; then
      python3 "$UTILS_DIR/k8s-error-summary.py" "$namespace" || true
    fi
    return 1
  fi

  log_ok
  return 0
}

#------------------------------------------------------------
# Description : Checks an HTTP endpoint is reachable (HTTP 2xx/3xx).
# Usage : check_endpoint <label> <url>
# Returns : 0 = reachable, 1 = not reachable
#------------------------------------------------------------
check_endpoint() {
  local label="$1"
  local url="$2"
  local http_code

  local timeout="${health_check_timeout:-30}"
  http_code=$(curl -sk --max-time "$timeout" -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")

  if [[ "$http_code" =~ ^[23] ]]; then
    log_ok
    return 0
  else

    log_error "Endpoint '$label' at $url — HTTP $http_code (unreachable or error)"
    return 1
  fi
}

#------------------------------------------------------------
# Description : Health check for infrastructure namespace.
#------------------------------------------------------------
test_infra() {
  local rc=0
  log_section "Health check: infra"

  log_step "Pods in namespace '$INFRA_NAMESPACE'"
  check_pods_ready "$INFRA_NAMESPACE" || rc=1

  log_step "Cluster default health endpoint"
  check_endpoint "Cluster" "http://${GAZELLE_DOMAIN}/health" || rc=1

  return $rc
}

#------------------------------------------------------------
# Description : Health check for MifosX / Fineract.
#------------------------------------------------------------
test_mifosx() {
  local rc=0
  log_section "Health check: MifosX"

  log_step "Pods in namespace '$MIFOSX_NAMESPACE'"
  check_pods_ready "$MIFOSX_NAMESPACE" || rc=1

  log_step "Fineract API health endpoint"
  check_endpoint "Fineract" "https://mifos.${GAZELLE_DOMAIN}/fineract-provider/actuator/health" || rc=1

  return $rc
}

#------------------------------------------------------------
# Description : Health check for Payment Hub EE.
#------------------------------------------------------------
test_phee() {
  local rc=0
  log_section "Health check: Payment Hub EE"

  log_step "Pods in namespace '$PH_NAMESPACE'"
  check_pods_ready "$PH_NAMESPACE" || rc=1

  log_step "Ops Web endpoint"
  check_endpoint "Ops Web" "http://ops.${GAZELLE_DOMAIN}" || rc=1

  log_step "Zeebe Operate endpoint"
  check_endpoint "Zeebe Operate" "http://zeebe-operate.${GAZELLE_DOMAIN}" || rc=1

  return $rc
}

#------------------------------------------------------------
# Description : Health check for Mojaloop vNext.
#------------------------------------------------------------
test_vnext() {
  local rc=0
  log_section "Health check: Mojaloop vNext"

  log_step "Pods in namespace '$VNEXT_NAMESPACE'"
  check_pods_ready "$VNEXT_NAMESPACE" || rc=1

  log_step "vNext Admin endpoint"
  check_endpoint "vNext Admin" "http://vnextadmin.${GAZELLE_DOMAIN}" || rc=1

  return $rc
}

#------------------------------------------------------------
# Description : Orchestrates health checks for selected components.
# Usage : test_apps <"app1 app2" | all>
# Example: test_apps "mifosx phee"
#------------------------------------------------------------
test_apps() {
  local appsToTest="$1"
  local overall_rc=0

  log_with_verbose_check "$debug" "$DEBUG" "Apps to test: $appsToTest"

  for app in $appsToTest; do
    case "$app" in
      "infra")
        test_infra   || overall_rc=1 ;;
      "mifosx")
        test_mifosx  || overall_rc=1 ;;
      "phee")
        test_phee    || overall_rc=1 ;;
      "vnext")
        test_vnext   || overall_rc=1 ;;
      *)
        log_error "Unknown app '$app' for testing. Valid: infra, mifosx, phee, vnext."
        overall_rc=1
        # Loop continues — remaining valid apps in $appsToTest will still be tested
        ;;
    esac
  done

  if [[ "$overall_rc" -eq 0 ]]; then
    log_banner "All health checks passed"
  else
    log_banner "One or more health checks FAILED"
  fi

  return $overall_rc
}