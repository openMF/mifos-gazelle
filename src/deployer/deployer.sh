#!/usr/bin/env bash
# deployer.sh -- the main Mifos Gazelle deployer script

source "$RUN_DIR/src/deployer/core.sh" || { echo "FATAL: Could not source core.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/deployer/vnext.sh" || { echo "FATAL: Could not source vnext.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/deployer/mifosx.sh" || { echo "FATAL: Could not source mifosx.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/deployer/phee.sh"   || { echo "FATAL: Could not source phee.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/deployer/mastercard.sh" || { echo "FATAL: Could not source mastercard.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/utils/helpers.sh" || { echo "FATAL: Could not source helpers.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }

#------------------------------------------------------------
# Description : Clones/updates a Git repo. Reclones only if repo or branch missing.
# Usage : clone_repo <branch> <repo_link> <target_dir> <dir_name>
# Example: clone_repo main link target-dir repo-name
#------------------------------------------------------------
clone_repo() {
  if [ "$#" -ne 4 ]; then
    echo "Usage: clone_repo <branch> <repo_link> <target_directory> <cloned_directory_name>"
    return 1
  fi

  local branch="$1"
  local repo_link="$2"
  local target_directory="$3"
  local cloned_directory_name="$4"
  local repo_path="$target_directory/$cloned_directory_name"

  # Create target directory if it doesn't exist
  run_as_user "mkdir -p \"$target_directory\" " >/dev/null 2>&1

  # Check if repository and branch exist
  if [ -d "$repo_path" ]; then
    cd "$repo_path" || return 1
    # Accept if branch exists as local ref, remote-tracking ref, or is currently checked out
    if git show-ref --verify --quiet "refs/heads/$branch" \
        || git show-ref --verify --quiet "refs/remotes/origin/$branch" \
        || [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$branch" ]; then
      return 0
    fi
    # Remove repo if branch doesn't exist anywhere
    echo "Branch $branch not found in $repo_path. Recloning..."
    rm -rf "$repo_path"
  fi

  # Clone the repository
  run_as_user "git clone -b \"$branch\" \"$repo_link\" \"$repo_path\" " >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    log_with_verbose_check "$debug" "$DEBUG" "Cloned $repo_link → $repo_path"
  else
    log_error "Failed to clone $repo_link to $repo_path"
    return 1
  fi
}

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
    all_namespaces_output=$(run_as_user "kubectl get namespaces -o name" 2>&1)
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
        if ! run_as_user "kubectl delete ns \"$namespace\" --ignore-not-found=true" >> /dev/null 2>&1 ; then
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

  # Build helm install command
  local helm_cmd="helm install --wait --timeout ${startup_timeout}s $release_name $chart_dir -n $namespace"
  if [ -n "$values_file" ]; then
      helm_cmd="$helm_cmd -f $values_file"
  fi

  run_as_user "$helm_cmd" #> /dev/null 2>&1
  check_command_execution $? "$helm_cmd"
  
  if is_app_running $namespace; then
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

  # Check if the namespace already exists
  if ! run_as_user "kubectl get namespace \"$namespace\"" >> /dev/null 2>&1; then
    # Create the namespace
    run_as_user "kubectl create namespace \"$namespace\"" >> /dev/null 2>&1
    check_command_execution $? "kubectl create namespace $namespace"
  fi

  # Configure Docker Hub authentication for this namespace
  # Script exits silently if DOCKERHUB_USERNAME/PASSWORD not set
  if [[ -f "$UTILS_DIR/k3s-docker-login.sh" ]]; then
    local docker_cmd="export DOCKERHUB_USERNAME='${DOCKERHUB_USERNAME:-}' DOCKERHUB_PASSWORD='${DOCKERHUB_PASSWORD:-}' DOCKERHUB_EMAIL='${DOCKERHUB_EMAIL:-}'; $UTILS_DIR/k3s-docker-login.sh \"$namespace\""
    if [ "$debug" = true ]; then
      run_as_user "$docker_cmd"
    else
      run_as_user "$docker_cmd" > /dev/null 2>&1
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
        run_as_user "kubectl apply -f $file -n $namespace" >> /dev/null 2>&1
        check_command_execution $? "kubectl apply -f $file -n $namespace"
      fi
  done

    # Apply other manifests
    for file in "$directory"/*.yaml; do
      if [[ "$file" != *persistence*.yaml && -f "$file" ]]; then
        run_as_user "kubectl apply -f $file -n $namespace" >> /dev/null 2>&1
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
    log_warn "Once the cluster is stable, re-run:  sudo $RUN_DIR/run.sh -a setup-data -f \"$CONFIG_FILE_PATH\""
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
      "phee")
        log_step "Removing Payment Hub EE"
        delete_resources_in_namespace_matching_pattern "$PH_NAMESPACE"
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
  if [[ "$appsToDeploy" != *"infra"* ]]; then
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
      "phee")
        deploy_ph
        ;;
      "mastercard-demo")
        if [[ "$redeploy" == "true" ]]; then
          delete_apps "mastercard-demo"
        fi
        if ! run_as_user "kubectl get namespace \"$PH_NAMESPACE\"" &> /dev/null; then
          log_error "Payment Hub namespace not found. Deploy phee first: ./run.sh -a phee"
          exit 1
        fi
        log_with_verbose_check "$debug" "$DEBUG" "MASTERCARD_CBS_HOME=$MASTERCARD_CBS_HOME"
        deploy_mastercard
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