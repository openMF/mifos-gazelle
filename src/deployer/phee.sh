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

  log_section "Deploying Payment Hub EE"

  if is_app_running "$PH_NAMESPACE"; then
    if [[ "$redeploy" == "false" ]]; then
      echo "    Payment Hub EE already deployed — skipping."
      return 0
    fi
  fi

  log_step "Removing existing Payment Hub resources"
  deleteResourcesInNamespaceMatchingPattern "$PH_NAMESPACE"
  manageElasticSecrets delete "$INFRA_NAMESPACE" "$APPS_DIR/$PHREPO_DIR/helm/es-secret"
  log_ok

  run_as_user "kubectl wait --for=condition=ready pod --all -n $VNEXT_NAMESPACE --timeout=600s" > /dev/null 2>&1

  log_step "Creating namespace $PH_NAMESPACE"
  createNamespace "$PH_NAMESPACE"
  log_ok

  prepare_payment_hub_chart

  log_step "Creating elastic secrets"
  manageElasticSecrets delete "$INFRA_NAMESPACE" "$APPS_DIR/$PHREPO_DIR/helm/es-secret"
  manageElasticSecrets create "$PH_NAMESPACE" "$APPS_DIR/$PHREPO_DIR/helm/es-secret"
  manageElasticSecrets create "$INFRA_NAMESPACE" "$APPS_DIR/$PHREPO_DIR/helm/es-secret"
  log_ok

  createIngressSecret "$PH_NAMESPACE" \
    "bulk-processor.$GAZELLE_DOMAIN" \
    "sandbox-secret" \
    "ops.$GAZELLE_DOMAIN,ops-bk.$GAZELLE_DOMAIN,api.$GAZELLE_DOMAIN,*.$GAZELLE_DOMAIN,localhost,ph-ee-connector-channel,ph-ee-connector-channel.$PH_NAMESPACE.svc.cluster.local"

  deployPhHelmChartFromDir "$PH_NAMESPACE" "$gazelleChartPath" "$PH_VALUES_FILE"

  local bpmns_to_deploy=$(ls -l "$BASE_DIR/orchestration/feel"/*.bpmn | wc -l)
  logWithVerboseCheck "$debug" "$DEBUG" "BPMNs to deploy: $bpmns_to_deploy"
  if are_bpmns_loaded $bpmns_to_deploy; then
    echo "    BPMN diagrams already loaded — skipping."
  else
    deploy_bpmns
  fi

  log_banner "Payment Hub EE Deployed"
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
  
  log_step "Updating FQDNs in Helm chart values and manifests"
  update_fqdn "$PH_VALUES_FILE" "mifos.gazelle.test" "$GAZELLE_DOMAIN" 
  update_fqdn "$PH_VALUES_FILE" "mifos.gazelle.localhost" "$GAZELLE_DOMAIN" 
  update_fqdn_batch "$APPS_DIR/ph_template" "mifos.gazelle.test" "$GAZELLE_DOMAIN"
  update_fqdn_batch "$APPS_DIR/ph_template" "mifos.gazelle.localhost" "$GAZELLE_DOMAIN"
  log_ok

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
  fi

  log_step "Helm install ($releaseName)"
  logWithVerboseCheck "$debug" "$DEBUG" "→ $helm_cmd"

  if [ "$debug" = true ]; then
    su - "$k8s_user" -c "bash -c '$helm_cmd'"
    install_exit_code=$?
  else
    output=$(su - "$k8s_user" -c "bash -c '$helm_cmd'" 2>&1)
    install_exit_code=$?
  fi

  su - "$k8s_user" -c "helm status $releaseName -n $namespace" > /tmp/helm_status_output 2>&1

  if grep -q "^STATUS: deployed" /tmp/helm_status_output; then
    log_ok
    return 0
  else
    log_failed "Helm release '$releaseName' did not reach deployed status"
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
  log_step "Deploying BPMN diagrams"

  for file in "$BPMNS_DIR"/*.bpmn; do
    if [ -f "$file" ]; then
      local cmd="curl --insecure --location --request POST $host \
          --header 'Platform-TenantId: greenbank' \
          --form 'file=@\"$file\"' \
          -s -o /dev/null -w '%{http_code}'"

      logWithVerboseCheck "$debug" "$DEBUG" "Uploading $(basename $file)"
      http_code=$(eval "$cmd")
      exit_code=$?

      if [ "$exit_code" -eq 0 ] && [ "$http_code" -eq 200 ]; then
          ((successful_uploads++))
      fi
      sleep 1
    else
      log_warn "No BPMN files found in $BPMNS_DIR"
    fi
  done

  if [ "$successful_uploads" -ge "$bpms_to_deploy" ]; then
    log_ok
  else
    log_warn "Some BPMN diagrams may not have deployed. Run: ./src/utils/deployBpmn-gazelle.sh"
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
#------------------------------------------------------------------------------
# Function: generate_sample_csvs
# Description: Generates sample bulk payment CSV files for closedloop and mojaloop
#              testing. Called from generateMifosXandVNextData() after Fineract is ready.
#              Files are gitignored and recreated on each deploy.
#------------------------------------------------------------------------------
generate_sample_csvs() {
    local csv_generator="$RUN_DIR/src/utils/data-loading/generate-example-csv-files.py"
    local output_dir="$RUN_DIR/src/utils/data-loading"

    if [ ! -f "$csv_generator" ]; then
            logWithVerboseCheck "$debug" "$WARNING" "CSV generator not found: $csv_generator"
        return 0
    fi

    log_step "Generating sample CSV files"

    > /tmp/phee-csv-gen.log  # always create a fresh log for this run

    local csv_exit=0
    if [ "$debug" == "true" ]; then
        run_as_user "python3 \"$csv_generator\" -c \"$CONFIG_FILE_PATH\" --mode closedloop --num-rows 4 --output-dir \"$output_dir\"" 2>&1 | tee -a /tmp/phee-csv-gen.log; csv_exit=$((csv_exit + ${PIPESTATUS[0]}))
        run_as_user "python3 \"$csv_generator\" -c \"$CONFIG_FILE_PATH\" --mode mojaloop --num-rows 4 --output-dir \"$output_dir\"" 2>&1 | tee -a /tmp/phee-csv-gen.log; csv_exit=$((csv_exit + ${PIPESTATUS[0]}))
    else
        run_as_user "python3 \"$csv_generator\" -c \"$CONFIG_FILE_PATH\" --mode closedloop --num-rows 4 --output-dir \"$output_dir\"" >> /tmp/phee-csv-gen.log 2>&1; csv_exit=$((csv_exit + $?))
        run_as_user "python3 \"$csv_generator\" -c \"$CONFIG_FILE_PATH\" --mode mojaloop --num-rows 4 --output-dir \"$output_dir\"" >> /tmp/phee-csv-gen.log 2>&1; csv_exit=$((csv_exit + $?))
    fi

    if [ "$csv_exit" -ne 0 ]; then
        log_warn "CSV generation failed — see /tmp/phee-csv-gen.log"
    else
        log_ok
    fi
}

#------------------------------------------------------------------------------
are_bpmns_loaded() {
    local MIN_REQUIRED=${1:-1}
    ES_URL="http://elasticsearch.$GAZELLE_DOMAIN" 
    INDEX="zeebe-record_process_*"

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

    [[ "$COUNT" =~ ^[0-9]+$ ]] || { logWithVerboseCheck "$debug" "$DEBUG" "ES query failed — assuming BPMNs not loaded"; return 1; }

    logWithVerboseCheck "$debug" "$DEBUG" "Unique BPMNs already deployed: $COUNT"
    (( COUNT >= MIN_REQUIRED )) && return 0 || return 1
}