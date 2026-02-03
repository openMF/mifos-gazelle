#!/usr/bin/env bash
# phee.sh -- Mifos Gazelle deployer script for PaymentHub EE 

#------------------------------------------------------------------------------
# Function : deployPH
# Description: Deploys PaymentHub EE using Helm charts.
#------------------------------------------------------------------------------
function deployPH(){
  gazelleChartPath="$APPS_DIR/$PH_EE_ENV_TEMPLATE_REPO_DIR/helm/gazelle"
  pheeEngineChartPath="$APPS_DIR/$PH_EE_ENV_TEMPLATE_REPO_DIR/helm/ph-ee-engine"

  # createIngressSecret "$PH_NAMESPACE"  \
  # "bulk-processor.$GAZELLE_DOMAIN" \
  # "sandbox-secret" \
  # "ops.$GAZELLE_DOMAIN,api.$GAZELLE_DOMAIN,*.$GAZELLE_DOMAIN,localhost"

  if is_app_running "$PH_NAMESPACE"; then
    if [[ "$redeploy" == "false" ]]; then
      echo "    $PH_RELEASE_NAME is already deployed. Skipping deployment."
      return 0
    fi 
  fi 
  # We are deploying or redeploying => make sure things are cleaned up first
  printf "    Redeploying paymenthub : Deleting existing resources in namespace %s\n" "$PH_NAMESPACE"
  deleteResourcesInNamespaceMatchingPattern "$PH_NAMESPACE"
  manageElasticSecrets delete "$INFRA_NAMESPACE" "$APPS_DIR/$PHREPO_DIR/helm/es-secret"
  run_as_user "kubectl wait --for=condition=ready pod --all -n $VNEXT_NAMESPACE --timeout=600s"
  #wait_for_pods_ready "$VNEXT_NAMESPACE"
  echo "==> Deploying PaymentHub EE"
  createNamespace "$PH_NAMESPACE"
  #checkPHEEDependencies
  prepare_payment_hub_chart
  manageElasticSecrets delete "$INFRA_NAMESPACE" "$APPS_DIR/$PHREPO_DIR/helm/es-secret"
  manageElasticSecrets create "$PH_NAMESPACE" "$APPS_DIR/$PHREPO_DIR/helm/es-secret"
  manageElasticSecrets create "$INFRA_NAMESPACE" "$APPS_DIR/$PHREPO_DIR/helm/es-secret"
  # old createIngressSecret "$PH_NAMESPACE" "$GAZELLE_DOMAIN" sandbox-secret
  createIngressSecret "$PH_NAMESPACE"  \
  "bulk-processor.$GAZELLE_DOMAIN" \
  "sandbox-secret" \
  "ops.$GAZELLE_DOMAIN,ops-bk.$GAZELLE_DOMAIN,api.$GAZELLE_DOMAIN,*.$GAZELLE_DOMAIN,localhost,ph-ee-connector-channel,ph-ee-connector-channel.$PH_NAMESPACE.svc.cluster.local"

  
  # now deploy the helm chart 
  deployPhHelmChartFromDir "$PH_NAMESPACE" "$gazelleChartPath" "$PH_VALUES_FILE"
  # now load the BPMS diagrams if they are not already loaded 
  
  # bpmns_to_deploy is the number of BPMS in the orchestration/feel directory
  local bpmns_to_deploy=$(ls -l "$BASE_DIR/orchestration/feel"/*.bpmn | wc -l) 
  echo "    BPMNs to deploy count is $bpmns_to_deploy"
  if are_bpmns_loaded $bpmns_to_deploy ; then
    echo "    BPMN diagrams are already loaded - skipping load "
  else
    deploy_bpmns
  fi
  echo -e "\n${GREEN}============================"
  echo -e "Paymenthub Deployed"
  echo -e "============================${RESET}\n"
}

#------------------------------------------------------------------------------
# Function : prepare_payment_hub_chart
# Description: Prepares the PaymentHub EE Helm chart by cloning necessary repositories
#              and updating FQDNs in values files and manifests.
#------------------------------------------------------------------------------
function prepare_payment_hub_chart() {
  # Clone the repositories
  cloneRepo "$PHBRANCH" "$PH_REPO_LINK" "$APPS_DIR" "$PHREPO_DIR"  # needed for kibana and elastic secrets only 
  cloneRepo "$PH_EE_ENV_TEMPLATE_REPO_BRANCH" "$PH_EE_ENV_TEMPLATE_REPO_LINK" "$APPS_DIR" "$PH_EE_ENV_TEMPLATE_REPO_DIR"
  
  # Update FQDNs in values file and manifests
  echo "    Updating FQDNs Helm chart values and manifests to use domain $GAZELLE_DOMAIN"
  update_fqdn "$PH_VALUES_FILE" "mifos.gazelle.test" "$GAZELLE_DOMAIN" 
  update_fqdn "$PH_VALUES_FILE" "mifos.gazelle.localhost" "$GAZELLE_DOMAIN" 
  update_fqdn_batch "$APPS_DIR/ph_template" "mifos.gazelle.test" "$GAZELLE_DOMAIN"
  update_fqdn_batch "$APPS_DIR/ph_template" "mifos.gazelle.localhost" "$GAZELLE_DOMAIN"
  
  # Run for ph-ee-engine
  phEEenginePath="$APPS_DIR/$PH_EE_ENV_TEMPLATE_REPO_DIR/helm/ph-ee-engine"
  ensure_helm_dependencies "$phEEenginePath"
  
  # Run for gazelle (parent)
  gazelleChartPath="$APPS_DIR/$PH_EE_ENV_TEMPLATE_REPO_DIR/helm/gazelle"
  ensure_helm_dependencies "$gazelleChartPath"
}

#------------------------------------------------------------------------------
# Function : deployPhHelmChartFromDir
# Description: Deploys a Helm chart for PaymentHub EE from a specified directory.
# Parameters:
#   $1 - Namespace to deploy to
#   $2 - Directory containing the Helm chart
#   $3 - (Optional) Values file for the Helm chart
#------------------------------------------------------------------------------
function deployPhHelmChartFromDir(){
  local namespace="$1"
  local chartDir="$2"      # Directory containing the Helm chart
  local valuesFile="$3"    # Values file for the Helm chart
  local releaseName="$PH_RELEASE_NAME"
  local timeout="1200s"

  # Construct install command
  local helm_cmd="helm install $releaseName $chartDir -n $namespace --wait --timeout $timeout"
  if [ -n "$valuesFile" ]; then
    helm_cmd="$helm_cmd -f $valuesFile"
    echo "    Installing Helm chart with values file: $valuesFile"
  else
    echo "    Installing Helm chart with default values..."
  fi

  # Run the install command and capture exit status
  if [ "$debug" = true ]; then
    echo "🔧 Running as $k8s_user: $helm_cmd"
    su - "$k8s_user" -c "bash -c '$helm_cmd'"
    install_exit_code=$?
  else
    output=$(su - "$k8s_user" -c "bash -c '$helm_cmd'" 2>&1)
    install_exit_code=$?
  fi

  # Verify status after install
  su - "$k8s_user" -c "helm status $releaseName -n $namespace" > /tmp/helm_status_output 2>&1
  local status_exit_code=$?

  if grep -q "^STATUS: deployed" /tmp/helm_status_output; then
    echo "    Helm release '$releaseName' deployed successfully."
    return 0
  else
    echo -e "${RED}    ❌ Helm install of release '$releaseName' has failed :${RESET}"
    exit 1
  fi
}

#------------------------------------------------------------------------------
# Function : deploy_bpmns
# Description: Deploys BPMN diagrams to Zeebe Operate.
#------------------------------------------------------------------------------
deploy_bpmns() {
  local host="https://zeebeops.$GAZELLE_DOMAIN/zeebe/upload"
  local DEBUG=false
  local successful_uploads=0
  local BPMNS_DIR="$BASE_DIR/orchestration/feel"  # BPMNs deployed from  Gazelle but probably eventually belong in ph-ee-env-template 
  local bpms_to_deploy=$(ls -l "$BPMNS_DIR"/*.bpmn | wc -l)
  printf "    Deploying BPMN diagrams from $BPMNS_DIR "

  # Find each .bpmn file in the specified directories and iterate over them
  for file in "$BPMNS_DIR"/*.bpmn;  do
    # Check if the glob expanded to an actual file or just returned the pattern
    if [ -f "$file" ]; then
      # Construct and execute the curl command for each file
      local cmd="curl --insecure --location --request POST $host \
          --header 'Platform-TenantId: greenbank' \
          --form 'file=@\"$file\"' \
          -s -o /dev/null -w '%{http_code}'"

      if [ "$DEBUG" = true ]; then
          echo "Executing: $cmd"
          http_code=$(eval "$cmd")
          exit_code=$?
          echo "HTTP Code: $http_code"
          echo "Exit code: $exit_code"
      else
          http_code=$(eval "$cmd")
          exit_code=$?
      fi 

      if [ "$exit_code" -eq 0 ] && [ "$http_code" -eq 200 ]; then
          ((successful_uploads++))
      fi
    else
      echo -e "${RED}** Warning : No BPMN files found in $BPMNS_DIR ${RESET}" 
    fi
  done

  # Check if the number of successful uploads meets the required threshold
  if [ "$successful_uploads" -ge "$bpms_to_deploy" ]; then
    echo " [ok] "
  else
    echo -e "${RED}Warning: there was an issue deploying the BPMN diagrams."
    echo -e "         run ./src/utils/deployBpmn-gazelle.sh to investigate${RESET}"
  fi
}

#------------------------------------------------------------------------------
# Function: are_bpmns_loaded
# Description: Checks if the required number of BPMN diagrams are loaded in Zeebe Operate.
# Parameters:
#   $1 - Minimum required number of BPMNs (default: 1)
# Returns:
#   0 if the required number of BPMNs are loaded, 1 otherwise.
#------------------------------------------------------------------------------
are_bpmns_loaded() {
    local MIN_REQUIRED=${1:-1}
    ES_URL="http://elasticsearch.$GAZELLE_DOMAIN" 
    INDEX="zeebe-record_process_8.2.12_2025-10-30"

    local COUNT=$(curl -s "$ES_URL/$INDEX/_search" \
        -H 'Content-Type: application/json' \
        -d '{
          "size": 0,
          "query": { "term": { "valueType": "PROCESS" } },
          "aggs": {
            "by_bpmn_id": {
              "composite": {
                "size": 1000,
                "sources": [ { "bpmn_id": { "terms": { "field": "value.bpmnProcessId" } } } ]
              },
              "aggs": { "latest_version": { "max": { "field": "value.version" } } }
            }
          }
        }' 2>/dev/null | jq -r '.aggregations.by_bpmn_id.buckets | length // 0')

    [[ "$COUNT" =~ ^[0-9]+$ ]] || { echo "[$(date +%T)] ERROR: ES query failed" >&2; return 1; }

    echo "    Unique BPMNs already deployed: $COUNT " >&2
    (( COUNT >= MIN_REQUIRED )) && return 0 || return 1
}