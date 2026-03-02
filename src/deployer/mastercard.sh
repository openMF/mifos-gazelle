#!/bin/bash
# Mastercard CBS Deployment Script for Mifos-Gazelle
# Integrates Mastercard CBS connector with PaymentHub using Kubernetes operator

# IMPORTANT: Do NOT use 'set -e' in scripts meant to be sourced
# This script is sourced by deployer.sh - 'set -e' would affect the parent shell
# and cause premature exits on any non-zero return code (like missing config values)

# IMPORTANT: Do not source commandline.sh here - it creates circular dependency
# This script is sourced by deployer.sh, which is already called from commandline.sh
# All necessary variables are already set in the environment
# logger.sh (GREEN/RESET/logWithLevel/logWithVerboseCheck) is available via helpers.sh

# Expand ~ to the actual user's home directory (handles sudo)
expand_tilde() {
    local path="$1"
    if [[ "$path" == "~"* ]]; then
        local user_home
        if [ -n "$SUDO_USER" ]; then
            user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        else
            user_home="$HOME"
        fi
        path="${user_home}${path:1}"
    fi
    echo "$path"
}

# Resolve config file path from run.sh -f flag, with fallbacks
resolve_config_file() {
    if [ -n "$CONFIG_FILE_PATH" ]; then
        expand_tilde "$CONFIG_FILE_PATH"
    elif [ -n "$RUN_DIR" ] && [ -f "$RUN_DIR/config/config.ini" ]; then
        echo "$RUN_DIR/config/config.ini"
    else
        expand_tilde "~/mifos-gazelle/config/config.ini"
    fi
}

check_prerequisites() {
    MASTERCARD_NAMESPACE="${MASTERCARD_NAMESPACE:-mastercard-demo}"
    MASTERCARD_ENABLED="${MASTERCARD_ENABLED:-true}"
    MASTERCARD_CBS_HOME="${MASTERCARD_CBS_HOME:-~/ph-ee-connector-mccbs}"
    MASTERCARD_CBS_HOME=$(expand_tilde "$MASTERCARD_CBS_HOME")
    MASTERCARD_API_URL="${MASTERCARD_API_URL:-https://sandbox.api.mastercard.com}"
    PAYMENTHUB_NAMESPACE="${PH_NAMESPACE:-paymenthub}"

    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install kubectl."
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        log_error "jq not found. Please install jq."
        exit 1
    fi

    if [ ! -d "$MASTERCARD_CBS_HOME" ]; then
        log_error "Mastercard CBS directory not found: $MASTERCARD_CBS_HOME"
        log_error "Set MASTERCARD_CBS_HOME or ensure ~/ph-ee-connector-mccbs exists"
        exit 1
    fi

    if ! run_as_user "kubectl get namespace \"$PAYMENTHUB_NAMESPACE\"" &> /dev/null; then
        log_warn "PaymentHub namespace not found: $PAYMENTHUB_NAMESPACE"
        log_warn "Mastercard CBS requires PaymentHub to be deployed first"
    fi
}

create_namespace() {
    logWithVerboseCheck "$debug" "$INFO" "Creating namespace: $MASTERCARD_NAMESPACE"

    run_as_user "kubectl create namespace $MASTERCARD_NAMESPACE --dry-run=client -o yaml" \
        | run_as_user "kubectl apply -f -" > /dev/null 2>&1

    run_as_user "kubectl label namespace $MASTERCARD_NAMESPACE \
        app.kubernetes.io/part-of=mifos-gazelle \
        app.kubernetes.io/component=mastercard-cbs --overwrite" > /dev/null 2>&1
}

create_secrets() {
    logWithVerboseCheck "$debug" "$INFO" "Creating Kubernetes secrets"

    if ! run_as_user "kubectl get secret mastercard-cbs-credentials -n $MASTERCARD_NAMESPACE" &> /dev/null; then
        run_as_user "kubectl create secret generic mastercard-cbs-credentials \
            -n $MASTERCARD_NAMESPACE \
            --from-literal=client_id=${MASTERCARD_CLIENT_ID:-demo} \
            --from-literal=client_secret=${MASTERCARD_CLIENT_SECRET:-demo} \
            --from-literal=partner_id=${MASTERCARD_PARTNER_ID:-MIFOS_GOVSTACK}" > /dev/null 2>&1
        logWithVerboseCheck "$debug" "$INFO" "Created mastercard-cbs-credentials secret"
    fi

    local signing_key_path encryption_cert_path decryption_key_path
    signing_key_path=$(expand_tilde "${MASTERCARD_SIGNING_KEY_PATH:-}")
    encryption_cert_path=$(expand_tilde "${MASTERCARD_ENCRYPTION_CERT_PATH:-}")
    decryption_key_path=$(expand_tilde "${MASTERCARD_DECRYPTION_KEY_PATH:-}")

    if [ -n "$signing_key_path" ]; then
        if ! run_as_user "kubectl get secret mastercard-cbs-certs -n $MASTERCARD_NAMESPACE" &> /dev/null; then
            if [ ! -f "$signing_key_path" ]; then
                log_error "MASTERCARD_SIGNING_KEY_PATH not found: $signing_key_path"
                return 1
            fi
            local cert_args="--from-file=signing-key.p12=${signing_key_path}"
            [ -n "$encryption_cert_path" ] && [ -f "$encryption_cert_path" ] && \
                cert_args="$cert_args --from-file=encryption-key.p12=${encryption_cert_path}"
            [ -n "$decryption_key_path" ] && [ -f "$decryption_key_path" ] && \
                cert_args="$cert_args --from-file=decryption-key.pem=${decryption_key_path}"
            run_as_user "kubectl create secret generic mastercard-cbs-certs \
                -n $MASTERCARD_NAMESPACE \
                $cert_args" > /dev/null 2>&1
            logWithVerboseCheck "$debug" "$INFO" "Created mastercard-cbs-certs secret from local cert files"
        fi
    else
        logWithVerboseCheck "$debug" "$WARNING" "MASTERCARD_SIGNING_KEY_PATH not set - certs must be bundled in Docker image (localdev only)"
    fi

    if run_as_user "kubectl get secret operationsmysql -n $PAYMENTHUB_NAMESPACE" &> /dev/null; then
        if ! run_as_user "kubectl get secret mysql-secret -n $MASTERCARD_NAMESPACE" &> /dev/null; then
            run_as_user "kubectl get secret operationsmysql -n $PAYMENTHUB_NAMESPACE -o json" \
                | jq --arg ns "$MASTERCARD_NAMESPACE" '
                    .metadata.namespace = $ns |
                    .metadata.name = "mysql-secret" |
                    .data.password = .data["mysql-root-password"] |
                    del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp)
                ' \
                | run_as_user "kubectl apply -f -" > /dev/null 2>&1
            logWithVerboseCheck "$debug" "$INFO" "Copied operationsmysql as mysql-secret to $MASTERCARD_NAMESPACE"
        fi
    else
        log_warn "operationsmysql secret not found in $PAYMENTHUB_NAMESPACE"
    fi
}

deploy_operator() {
    local operator_dir="$RUN_DIR/src/deployer/operators/mastercard"

    if [ ! -d "$operator_dir" ]; then
        log_error "Operator directory not found: $operator_dir"
        exit 1
    fi

    local config_file
    config_file=$(resolve_config_file)
    logWithVerboseCheck "$debug" "$INFO" "Deploying operator with config: $config_file"

    cd "$operator_dir"
    if [ "$debug" == "true" ]; then
        run_as_user "bash '$operator_dir/deploy-operator.sh' -c '$config_file' deploy"
    else
        run_as_user "bash '$operator_dir/deploy-operator.sh' -c '$config_file' deploy" > /dev/null 2>&1
    fi
    local rc=$?
    cd "$RUN_DIR"

    if [ $rc -ne 0 ]; then
        log_error "Failed to deploy operator"
        exit 1
    fi
}

deploy_connector() {
    # Determine API URL
    local api_url="$MASTERCARD_API_URL"

    # Determine image settings
    local image_repo="ph-ee-connector-mastercard-cbs"
    local image_tag="1.0.0"
    local localdev_section=""

    if [ "${MASTERCARD_LOCALDEV_ENABLED:-false}" == "true" ]; then
        logWithVerboseCheck "$debug" "$INFO" "Connector local development mode enabled"
        image_repo="eclipse-temurin"
        image_tag="17"
        localdev_section="  localdev:
    enabled: true
    hostPath: \"${MASTERCARD_CBS_HOME}\"
    jarPath: \"/app/build/libs/ph-ee-connector-mastercard-cbs-1.0.0-SNAPSHOT.jar\""
    fi

    local cr_file="/tmp/mastercard-cbs-cr.yaml"
    cat > "$cr_file" <<EOF
apiVersion: paymenthub.mifos.io/v1alpha1
kind: MastercardCBSConnector
metadata:
  name: mastercard-cbs
  namespace: ${MASTERCARD_NAMESPACE}
spec:
  enabled: ${MASTERCARD_ENABLED}
  replicas: 1
  image:
    repository: ${image_repo}
    tag: "${image_tag}"
    pullPolicy: IfNotPresent
  mastercard:
    apiUrl: "${api_url}"
    clientSecretName: "mastercard-cbs-credentials"
  paymenthub:
    namespace: "${PAYMENTHUB_NAMESPACE}"
    zeebeGateway: "phee-zeebe-gateway.${PAYMENTHUB_NAMESPACE}.svc.cluster.local:26500"
    operationsDb:
      host: "operationsmysql.${PAYMENTHUB_NAMESPACE}.svc.cluster.local"
      port: 3306
      database: "operations"
      secretName: "mysql-secret"
  dataLoading:
    autoLoad: true
    demoPayeeCount: 10
  workflow:
    autoDeploy: false
${localdev_section}
  resources:
    limits:
      cpu: "500m"
      memory: "512Mi"
    requests:
      cpu: "250m"
      memory: "256Mi"
EOF
    chmod 644 "$cr_file"
    logWithVerboseCheck "$debug" "$INFO" "Applying connector CR from $cr_file"

    local apply_output
    apply_output=$(run_as_user "kubectl apply -f '$cr_file' 2>&1")
    local rc=$?

    if [ $rc -ne 0 ]; then
        log_error "Failed to apply connector CR: $apply_output"
        return 1
    fi
    logWithVerboseCheck "$debug" "$INFO" "Connector CR: $apply_output"
}

wait_for_deployment() {
    log_step "Waiting for Mastercard connector pods"
    local timeout=300
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        if run_as_user "kubectl get deployment ph-ee-connector-mastercard-cbs -n \"$MASTERCARD_NAMESPACE\"" &> /dev/null; then
            if run_as_user "kubectl wait --for=condition=available --timeout=30s \
                deployment/ph-ee-connector-mastercard-cbs -n \"$MASTERCARD_NAMESPACE\"" &> /dev/null; then
                break
            fi
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    log_ok
}

deploy_bpmn_workflow() {
    local workflow_file="$MASTERCARD_CBS_HOME/orchestration/MastercardFundTransfer-DFSPID.bpmn"
    local deploy_script="$RUN_DIR/src/utils/deployBpmn-gazelle.sh"

    if [ ! -f "$workflow_file" ]; then
        log_warn "BPMN workflow not found: $workflow_file"
        return 1
    fi

    if [ ! -f "$deploy_script" ]; then
        log_warn "deployBpmn-gazelle.sh not found: $deploy_script"
        return 1
    fi

    local config_file
    config_file=$(resolve_config_file)

    if [ ! -f "$config_file" ]; then
        log_error "Config file not found: $config_file"
        return 1
    fi

    logWithVerboseCheck "$debug" "$INFO" "Deploying BPMN workflow for greenbank"
    if run_as_user "bash \"$deploy_script\" -c \"$config_file\" -f \"$workflow_file\" -t greenbank" > /dev/null 2>&1; then
        logWithVerboseCheck "$debug" "$DEBUG" "BPMN deployed for greenbank"
    else
        log_warn "Failed to deploy BPMN workflow for greenbank"
        return 1
    fi

    for tenant in redbank bluebank; do
        if run_as_user "bash \"$deploy_script\" -c \"$config_file\" -f \"$workflow_file\" -t $tenant" > /dev/null 2>&1; then
            logWithVerboseCheck "$debug" "$DEBUG" "BPMN deployed for $tenant"
        else
            logWithVerboseCheck "$debug" "$DEBUG" "Skipped $tenant (tenant may not exist)"
        fi
    done
}

load_supplementary_data() {
    local data_loader="$RUN_DIR/src/utils/mastercard/load-mastercard-supplementary-data.sh"
    local config_file
    config_file=$(resolve_config_file)

    if [ ! -f "$data_loader" ]; then
        log_warn "Supplementary data loader not found: $data_loader"
        return 0
    fi

    if [ ! -f "$config_file" ]; then
        log_warn "Config file not found, skipping supplementary data load"
        return 0
    fi

    logWithVerboseCheck "$debug" "$INFO" "Loading supplementary data via $data_loader"
    if [ "$debug" == "true" ]; then
        run_as_user "bash \"$data_loader\" -c \"$config_file\""
    else
        run_as_user "bash \"$data_loader\" -c \"$config_file\"" > /tmp/mastercard-data-load.log 2>&1
    fi

    if [ $? -ne 0 ]; then
        log_warn "Supplementary data load failed (see /tmp/mastercard-data-load.log)"
    fi
}

generate_mastercard_csv() {
    local csv_generator="$RUN_DIR/src/utils/data-loading/generate-example-csv-files.py"
    local config_file
    config_file=$(resolve_config_file)

    if [ ! -f "$csv_generator" ]; then
        log_warn "CSV generator not found: $csv_generator"
        return 0
    fi

    if [ ! -f "$config_file" ]; then
        log_warn "Config file not found, skipping CSV generation"
        return 0
    fi

    local output_dir="$RUN_DIR/src/utils/data-loading"
    logWithVerboseCheck "$debug" "$INFO" "Generating bulk-gazelle-mastercard-6.csv"
    if [ "$debug" == "true" ]; then
        run_as_user "python3 \"$csv_generator\" -c \"$config_file\" --mode mastercard --num-rows 6 --output-dir \"$output_dir\""
    else
        run_as_user "python3 \"$csv_generator\" -c \"$config_file\" --mode mastercard --num-rows 6 --output-dir \"$output_dir\"" > /tmp/mastercard-csv-gen.log 2>&1
    fi

    if [ $? -ne 0 ]; then
        log_warn "CSV generation failed (see /tmp/mastercard-csv-gen.log)"
    fi
}

configure_payment_mode() {
    logWithVerboseCheck "$debug" "$INFO" "Payment mode MASTERCARD_CBS requires bulk-processor config:"
    logWithVerboseCheck "$debug" "$INFO" "  payment-modes: [{id: MASTERCARD_CBS, type: BULK, endpoint: bulk_connector_mastercard_cbs-{dfspid}}]"
    if [ -d "$HOME/ph-ee-bulk-processor" ]; then
        logWithVerboseCheck "$debug" "$INFO" "Hostpath detected - rebuild JAR and restart pod after editing application.yaml"
    fi
}

verify_deployment() {
    if [ "$debug" == "true" ]; then
        echo ""
        echo "    Custom Resource:"
        run_as_user "kubectl get mastercardcbsconnector -n $MASTERCARD_NAMESPACE" || \
            log_warn "CR not found"
        echo ""
        echo "    Pods:"
        run_as_user "kubectl get pods -n $MASTERCARD_NAMESPACE"
        echo ""
        echo "    Services:"
        run_as_user "kubectl get svc -n $MASTERCARD_NAMESPACE"
    fi
}

cleanup() {
    MASTERCARD_NAMESPACE="${MASTERCARD_NAMESPACE:-mastercard-demo}"
    local operator_dir="${RUN_DIR:-$HOME/mifos-gazelle}/src/deployer/operators/mastercard"

    run_as_user "kubectl delete mastercardcbsconnector mastercard-cbs \
        -n \"$MASTERCARD_NAMESPACE\" --ignore-not-found=true" > /dev/null 2>&1

    sleep 10

    if [ -f "$operator_dir/deploy-operator.sh" ]; then
        run_as_user "cd \"$operator_dir\" && bash deploy-operator.sh undeploy" > /dev/null 2>&1
    fi

    run_as_user "kubectl delete namespace \"$MASTERCARD_NAMESPACE\" --ignore-not-found=true" > /dev/null 2>&1
}

deploy_mastercard() {
    log_section "Deploying Mastercard CBS"
    check_prerequisites
    logWithVerboseCheck "$debug" "$DEBUG" "Namespace: $MASTERCARD_NAMESPACE"

    log_step "Creating namespace $MASTERCARD_NAMESPACE"
    create_namespace
    log_ok

    log_step "Creating secrets"
    create_secrets
    log_ok

    log_step "Deploying operator"
    deploy_operator
    log_ok

    sleep 5

    log_step "Deploying connector CR"
    deploy_connector
    log_ok

    wait_for_deployment

    log_step "Deploying BPMN workflow"
    deploy_bpmn_workflow
    log_ok

    log_step "Loading supplementary data"
    load_supplementary_data
    log_ok

    log_step "Generating sample CSV (6 rows)"
    generate_mastercard_csv
    log_ok

    configure_payment_mode
    verify_deployment

    log_banner "Mastercard CBS Deployed"
    echo "  Namespace:  $MASTERCARD_NAMESPACE"
    echo "  Sample CSV: $RUN_DIR/src/utils/data-loading/bulk-gazelle-mastercard-6.csv"
    echo
}

# Main entry point (only used when script is executed directly, not sourced)
main() {
    set -e
    # When run directly, default debug to false if not set
    debug="${debug:-false}"
    case "${1:-deploy}" in
        deploy)
            deploy_mastercard
            ;;
        undeploy|cleanup)
            cleanup
            ;;
        verify)
            debug="true"
            verify_deployment
            ;;
        status)
            run_as_user "kubectl get mastercardcbsconnector -n ${MASTERCARD_NAMESPACE:-mastercard-demo}"
            run_as_user "kubectl get pods -n ${MASTERCARD_NAMESPACE:-mastercard-demo}"
            ;;
        *)
            echo "Usage: $0 {deploy|undeploy|verify|status}"
            exit 1
            ;;
    esac
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    main "$@"
fi
