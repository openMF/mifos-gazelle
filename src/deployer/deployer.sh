#!/usr/bin/env bash
# deployer.sh -- the main Mifos Gazelle deployer script

source "$RUN_DIR/src/deployer/core.sh" || { echo "FATAL: Could not source core.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/deployer/vnext.sh" || { echo "FATAL: Could not source vnext.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/deployer/mifosx.sh" || { echo "FATAL: Could not source mifosx.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/deployer/phee.sh"   || { echo "FATAL: Could not source phee.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }  
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
    echo "    Repository $repo_path cloned successfully."
  else
    echo "Failed to clone $repo_link to $repo_path."
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
        echo "  ** Error: need to specify resources to delete  ."
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
            echo " [FAILED]"
            echo "Failed to delete namespace $namespace. Check logs for details."
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
    echo "Error: Chart directory '$chart_dir' does not exist."
    return 1
  fi

  # Build helm install command
  local helm_cmd="helm install --wait --timeout 600s $release_name $chart_dir -n $namespace"
  if [ -n "$values_file" ]; then
      helm_cmd="$helm_cmd -f $values_file"
  fi

  run_as_user "$helm_cmd" #> /dev/null 2>&1
  check_command_execution $? "$helm_cmd"
  
  if is_app_running $namespace; then
    echo "Helm chart deployed successfully."
    return 0
  else
    echo -e "${RED}Helm chart deployment failed.${RESET}"
    return 1
  fi
}

#------------------------------------------------------------
# Description : Creates a K8s namespace if it doesn't exist.
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
}

#------------------------------------------------------------
# Description : Deploys infrastructure chart via Helm.
# Usage : deployInfrastructure [redeploy_bool]
# Example: deployInfrastructure true
#------------------------------------------------------------
function deployInfrastructure() {
  local redeploy="${1:-false}"

  printf "==> Deploying infrastructure \n"

  if is_app_running  "$INFRA_NAMESPACE"; then
    if [[ "$redeploy" == "false" ]]; then
        echo "    Infrastructure is already deployed. Skipping deployment."
        return 0
    else
        printf "    Redeploying infrastructure : Deleting existing resources in namespace %s\n" "$INFRA_NAMESPACE"
        deleteResourcesInNamespaceMatchingPattern "$INFRA_NAMESPACE"
    fi
  fi

  createNamespace "$INFRA_NAMESPACE"
  check_command_execution $? "createNamespace $INFRA_NAMESPACE"

  # ensure we use the right domain name  in infra chart
  echo "    Updating FQDNs in INFRA Helm chart values.yaml to use domain $GAZELLE_DOMAIN"
  update_fqdn "$INFRA_CHART_DIR/values.yaml" "mifos.gazelle.test" "$GAZELLE_DOMAIN" 
  update_fqdn "$INFRA_CHART_DIR/values.yaml" "mifos.gazelle.localhost" "$GAZELLE_DOMAIN" 

  # Update helm dependencies for infra chart
  # run_as_user "cd $INFRA_CHART_DIR && helm dep update" # >> /dev/null 2>&1
  # check_command_execution $? "helm dep update for infra chart"

  # make sure helm chart dependencies are up to date
  ensure_helm_dependencies "$INFRA_CHART_DIR"

  # Deploy infra helm chart
  printf "    Deploying infra helm chart  "
  if [ "$debug" = true ]; then
    deployHelmChartFromDir "$RUN_DIR/src/deployer/helm/infra" "$INFRA_NAMESPACE" "$INFRA_RELEASE_NAME"
    check_command_execution $? "deployHelmChartFromDir infra"
  else 
    deployHelmChartFromDir "$RUN_DIR/src/deployer/helm/infra" "$INFRA_NAMESPACE" "$INFRA_RELEASE_NAME" >> /dev/null 2>&1
    check_command_execution $? "deployHelmChartFromDir infra"
  fi
  echo " [ok] "
  
  echo -e "\n${GREEN}============================"
  echo -e "Infrastructure Deployed"
  echo -e "============================${RESET}\n"
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
        echo "Error: Directory '$directory' not found."
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
  cat << EOF

=================================
Mifos Gazelle "cleanup" complete
=================================

EOF
}

#------------------------------------------------------------
# Description : Prints final deployment status and access info.
# Usage : print_deployment_end_message
# Example: print_deployment_end_message
#------------------------------------------------------------
function print_deployment_end_message() {
  cat << EOF
=================================
Thank you for using Mifos Gazelle
=================================

CHECK DEPLOYMENTS USING kubectl
kubectl get pods -n vnext         # For testing mojaloop vNext
kubectl get pods -n paymenthub    # For testing PaymentHub EE
kubectl get pods -n mifosx        # For testing MifosX

or using k9s with $HOME/local/bin/k9s <cr> 
EOF
}

#------------------------------------------------------------
# Description : Deletes all or specific applications by namespace.
# Usage : deleteApps <ignored> <"app1 app2"|all>
# Example: deleteApps _ "mifosx vnext"
#------------------------------------------------------------
function deleteApps() {
  local appsToDelete="$1"
  
  for app in $appsToDelete; do
    echo -e "${BLUE}Deleting application: $app...${RESET}"
    case "$app" in
      "vnext")
        printf "    deleting vnext "
        deleteResourcesInNamespaceMatchingPattern "$VNEXT_NAMESPACE"
        printf "                                 [ok]\n"
        ;;
      "mifosx")
        printf "    deleting mifosx"
        deleteResourcesInNamespaceMatchingPattern "$MIFOSX_NAMESPACE"
        printf "                                 [ok]\n"
        ;;
      "phee")
        printf "    deleting paymenthub "
        deleteResourcesInNamespaceMatchingPattern "$PH_NAMESPACE"
        printf "                            [ok]\n"
        ;;
      "infra")
        printf "    deleting infrastructure  "
        deleteResourcesInNamespaceMatchingPattern "$INFRA_NAMESPACE"
        printf "                       [ok]\n"

        ;;
      *)
        echo -e "${RED}Invalid app '$app' for deletion. This should have been caught by validateInputs.${RESET}"
        showUsage
        exit 1
        ;;
    esac
  done
  
  print_cleanup_end_message
}


# --- GAZ-215: Timer Functions ---
declare -a COMPONENT_NAMES
declare -a COMPONENT_TIMES

function start_timer() {
    if [ -z "${ENABLE_TIMERS}" ]; then
        # we look for ENABLE_TIMERS with grep
        if [ -f "config/config.ini" ]; then
            ENABLE_TIMERS=$(grep "^ENABLE_TIMERS=" config/config.ini | cut -d'=' -f2 | tr -d ' ' | tr -d '"' | tr -d "'")
        fi
    fi
    
    if [ "${ENABLE_TIMERS}" == "true" ]; then
        CURRENT_COMPONENT="$1"
        START_TIME=$(date +%s)
        echo "------------------------------------------------"
        echo " [GAZ-215] Starting deployment of: $CURRENT_COMPONENT"
        echo "------------------------------------------------"
    fi
}

function stop_timer() {
    if [ "${ENABLE_TIMERS}" == "true" ] && [ -n "$START_TIME" ]; then
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        COMPONENT_NAMES+=("$CURRENT_COMPONENT")
        COMPONENT_TIMES+=("$DURATION")
        echo "Finished $CURRENT_COMPONENT in ${DURATION} seconds."
    fi
}

function print_final_summary() {
    if [ "${ENABLE_TIMERS}" == "true" ]; then
        echo ""
        echo "==================================================="
        echo "   DEPLOYMENT TIMING SUMMARY (GAZ-215) "
        echo "==================================================="
        if [ ${#COMPONENT_NAMES[@]} -eq 0 ]; then
            echo "   No components tracked."
        else
            for i in "${!COMPONENT_NAMES[@]}"; do
                printf "   %-25s : %s seconds\n" "${COMPONENT_NAMES[$i]}" "${COMPONENT_TIMES[$i]}"
            done
        fi
        echo "==================================================="
        echo ""
    fi
}
# --------------------------------




#------------------------------------------------------------
# Description : Orchestrates deployment of apps (infra, vnext, etc.).
# Usage : deployApps <"app1 app2"... > [redeploy]
# Example: deployApps _ "vnext mifosx" true
#------------------------------------------------------------
function deployApps() {
  local appsToDeploy="$1"
  local redeploy="${2:-false}"

  echo "Starting deployment for applications: $appsToDeploy..."
  # Process each application in the space-separated list
  for app in $appsToDeploy; do     
    echo -e "${BLUE}Deploying application: $app...${RESET}"  
    case "$app" in
      "infra")
        start_timer "Infrastructure"
        deployInfrastructure "$redeploy"
        stop_timer
        ;;
      "vnext")
        
        deployInfrastructure "false"  # deploy infra if not already there even if redeploy=true
        start_timer "vNext"
        deployvNext
        stop_timer
        ;;
      "mifosx")
        # if [[ "$redeploy" == "true" ]]; then 
        #   #echo "Removing current mifosx and redeploying"
        #   deleteApps "mifosx"
          
        # fi 
        deployInfrastructure "false"  # deploy infra if not already there even if redeploy=true
        start_timer "MifosX"
        DeployMifosXfromYaml "$MIFOSX_MANIFESTS_DIR" 
        generateMifosXandVNextData
        stop_timer
        ;;
      "phee")
        deployInfrastructure "false"
        start_timer "deployPH"
        deployPH
        stop_timer
        ;;
      *)
        echo -e "${RED}Error: Unknown application '$app' in deployment list. This should have been caught by validation.${RESET}"
        showUsage
        exit 1
        ;;
    esac
  done

  print_deployment_end_message
}