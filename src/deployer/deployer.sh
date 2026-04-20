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
# Usage : cloneRepo <branch> <repo_link> <target_dir> <dir_name>
# Example: cloneRepo main link target-dir repo-name
#------------------------------------------------------------
function cloneRepo() {
  if [ "$#" -ne 4 ]; then
    echo "Usage: cloneRepo <branch> <repo_link> <target_directory> <cloned_directory_name>"
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
    # Check if specified branch exists locally
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      return 0
    fi
    # Remove repo if branch doesn't exist
    echo "Branch $branch not found in $repo_path. Recloning..."
    rm -rf "$repo_path"
  fi

  # Clone the repository
  run_as_user "git clone -b \"$branch\" \"$repo_link\" \"$repo_path\" " >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    logWithVerboseCheck "$debug" "$DEBUG" "Cloned $repo_link → $repo_path"
  else
    log_error "Failed to clone $repo_link to $repo_path"
    return 1
  fi
}

#------------------------------------------------------------
# Description : Deletes K8s namespaces matching a regex pattern.
# Usage : deleteResourcesInNamespaceMatchingPattern <regex_pattern>
# Example: deleteResourcesInNamespaceMatchingPattern "app-.*"
#------------------------------------------------------------
function deleteResourcesInNamespaceMatchingPattern() {
    local pattern="$1"
    if [ -z "$pattern" ]; then
        log_error "deleteResourcesInNamespaceMatchingPattern: pattern argument required"
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
        # printf "      namespaces %s not found    [skipping] \n"  $pattern
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
# Usage : deployHelmChartFromDir <dir> <ns> <release> [values_file]
# Example: deployHelmChartFromDir ./chart infra infra-rls values.yaml
#------------------------------------------------------------
function deployHelmChartFromDir() {
  if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "Usage: deployHelmChartFromDir <chart_dir> <namespace> <release_name> [values_file]"
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
  local helm_cmd="helm install --wait --timeout $startup_timeout $release_name $chart_dir -n $namespace"
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
# Usage : createNamespace <namespace>
# Example: createNamespace mifosx-ns
#------------------------------------------------------------
function createNamespace() {
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
# Usage : deployInfrastructure [redeploy_bool]
# Example: deployInfrastructure true
#------------------------------------------------------------
function deployInfrastructure() {
  local redeploy="${1:-false}"

  if is_app_running "$INFRA_NAMESPACE" && [[ "$redeploy" == "false" ]]; then
    return 0
  fi

  log_section "Deploying infrastructure"

  if is_app_running "$INFRA_NAMESPACE"; then
    log_step "Removing existing infrastructure"
    deleteResourcesInNamespaceMatchingPattern "$INFRA_NAMESPACE"
    log_ok
  fi

  log_step "Creating namespace $INFRA_NAMESPACE"
  createNamespace "$INFRA_NAMESPACE"
  check_command_execution $? "createNamespace $INFRA_NAMESPACE"
  log_ok

  log_step "Updating FQDNs"
  update_fqdn "$INFRA_CHART_DIR/values.yaml" "mifos.gazelle.test" "$GAZELLE_DOMAIN"
  update_fqdn "$INFRA_CHART_DIR/values.yaml" "mifos.gazelle.localhost" "$GAZELLE_DOMAIN"
  log_ok

  ensure_helm_dependencies "$INFRA_CHART_DIR"

  log_step "Helm chart (infra)"
  if [ "$debug" = true ]; then
    deployHelmChartFromDir "$RUN_DIR/src/deployer/helm/infra" "$INFRA_NAMESPACE" "$INFRA_RELEASE_NAME"
  else
    deployHelmChartFromDir "$RUN_DIR/src/deployer/helm/infra" "$INFRA_NAMESPACE" "$INFRA_RELEASE_NAME" >> /dev/null 2>&1
  fi
  check_command_execution $? "deployHelmChartFromDir infra"
  log_ok

  log_banner "Infrastructure Deployed"
}

#------------------------------------------------------------
# Description : Applies K8s YAML manifests from a directory.
# Usage : applyKubeManifests <directory> <namespace>
# Example: applyKubeManifests ./k8s-files mifosx-ns
#------------------------------------------------------------
function applyKubeManifests() {
    if [ "$#" -ne 2 ]; then
        echo "Usage: applyKubeManifests <directory> <namespace>"
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
# Description : Placeholder for vNext application testing logic.
# Usage : test_vnext
# Example: test_vnext
#------------------------------------------------------------
function test_vnext() {
  echo "TODO" #TODO Write function to test apps
}

#------------------------------------------------------------
# Description : Placeholder for Phee application testing logic.
# Usage : test_phee
# Example: test_phee
#------------------------------------------------------------
function test_phee() {
  echo "TODO"
}

#------------------------------------------------------------
# Description : Placeholder for MifosX application testing logic.
# Usage : test_mifosx <instance_name>
# Example: test_mifosx default
#------------------------------------------------------------
function test_mifosx() {
  local instance_name=$1
  # TODO: Implement testing logic
}

#------------------------------------------------------------
# Description : Prints cleanup end message .
#------------------------------------------------------------
function print_cleanup_end_message() {
  log_banner "Cleanup Complete"
  echo
}

#------------------------------------------------------------
# Description : Prints final deployment status and access info.
# Usage : print_deployment_end_message
# Example: print_deployment_end_message
#------------------------------------------------------------
function print_deployment_end_message() {
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
# Usage : deleteApps <ignored> <"app1 app2"|all>
# Example: deleteApps _ "mifosx vnext"
#------------------------------------------------------------
function deleteApps() {
  local appsToDelete="$1"

  log_section "Removing applications"
  for app in $appsToDelete; do
    case "$app" in
      "vnext")
        log_step "Removing vNext"
        deleteResourcesInNamespaceMatchingPattern "$VNEXT_NAMESPACE"
        log_ok
        ;;
      "mifosx")
        log_step "Removing MifosX"
        deleteResourcesInNamespaceMatchingPattern "$MIFOSX_NAMESPACE"
        log_ok
        ;;
      "phee")
        log_step "Removing Payment Hub EE"
        deleteResourcesInNamespaceMatchingPattern "$PH_NAMESPACE"
        log_ok
        ;;
      "infra")
        log_step "Removing infrastructure"
        deleteResourcesInNamespaceMatchingPattern "$INFRA_NAMESPACE"
        log_ok
        ;;
      "mastercard-demo")
        log_step "Removing Mastercard demo"
        cleanup
        log_ok
        ;;
      *)
        log_error "Invalid app '$app' for deletion. This should have been caught by validateInputs."
        showUsage
        exit 1
        ;;
    esac
  done

  print_cleanup_end_message
}

#------------------------------------------------------------
# Description : Orchestrates deployment of apps (infra, vnext, etc.).
# Usage : deployApps <"app1 app2"... > [redeploy]
# Example: deployApps _ "vnext mifosx" true
#------------------------------------------------------------
function deployApps() {
  local appsToDeploy="$1"
  local redeploy="${2:-false}"
  local data_gen_failed=false

  logWithVerboseCheck "$debug" "$DEBUG" "Apps to deploy: $appsToDeploy (redeploy=$redeploy)"

  for app in $appsToDeploy; do
    case "$app" in
      "infra")
        deployInfrastructure "$redeploy"
        ;;
      "vnext")
        deployInfrastructure "false"
        deployvNext
        ;;
      "mifosx")
        deployInfrastructure "false"
        DeployMifosXfromYaml "$MIFOSX_MANIFESTS_DIR"
        if ! generateMifosXandVNextData; then
          data_gen_failed=true
        fi
        ;;
      "setup-data")
        if ! generateMifosXandVNextData; then
          data_gen_failed=true
        fi
        ;;
      "phee")
        deployInfrastructure "false"
        deployPH
        ;;
      "mastercard-demo")
        if [[ "$redeploy" == "true" ]]; then
          deleteApps "mastercard-demo"
        fi
        deployInfrastructure "false"
        if ! run_as_user "kubectl get namespace \"$PH_NAMESPACE\"" &> /dev/null; then
          log_error "Payment Hub namespace not found. Deploy phee first: ./run.sh -a phee"
          exit 1
        fi
        logWithVerboseCheck "$debug" "$DEBUG" "MASTERCARD_CBS_HOME=$MASTERCARD_CBS_HOME"
        deploy_mastercard
        ;;
      *)
        log_error "Unknown application '$app'. This should have been caught by validation."
        showUsage
        exit 1
        ;;
    esac
  done

  print_deployment_end_message "$data_gen_failed"
}