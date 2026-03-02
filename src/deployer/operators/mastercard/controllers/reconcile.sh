#!/bin/bash
# Mastercard CBS Operator - Reconciliation Controller
# This is a shell-based operator controller that can be migrated to Go later

set -e

# Logging functions
log_info() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $*"; }
log_warn() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] WARN: $*" >&2; }
log_error() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

# Reconcile function - main controller logic
reconcile() {
    local cr_name="$1"
    local namespace="$2"
    local config_file="$3"

    log_info "Reconciling MastercardCBSConnector: $cr_name in namespace: $namespace"

    # Get the CR spec
    local cr_json
    cr_json=$(kubectl get mastercardcbsconnector "$cr_name" -n "$namespace" -o json 2>/dev/null || echo "{}")

    if [ "$cr_json" == "{}" ]; then
        log_warn "CR $cr_name not found in namespace $namespace"
        return 1
    fi

    # Extract spec fields
    local enabled
    enabled=$(echo "$cr_json" | jq -r '.spec.enabled // false')

    if [ "$enabled" != "true" ]; then
        log_info "Connector is disabled, ensuring resources are cleaned up..."
        cleanup_resources "$cr_name" "$namespace"
        update_status "$cr_name" "$namespace" "Disabled"
        return 0
    fi

    # Update status to Initializing
    update_status "$cr_name" "$namespace" "Initializing"

    # Phase 1: Ensure namespace exists
    ensure_namespace "$namespace"

    # Phase 1.5: Copy MySQL secret from paymenthub
    copy_mysql_secret "$namespace" "$cr_json"

    # Phase 2: Create database schema and load data
    if [ "$(echo "$cr_json" | jq -r '.spec.dataLoading.autoLoad // true')" == "true" ]; then
        load_database_data "$cr_name" "$namespace" "$cr_json" "$config_file"
    fi

    # Phase 3: Deploy connector
    deploy_connector "$cr_name" "$namespace" "$cr_json" "$config_file"

    # Phase 5: Deploy BPMN workflow
    if [ "$(echo "$cr_json" | jq -r '.spec.workflow.autoDeploy // true')" == "true" ]; then
        deploy_workflow "$cr_name" "$namespace" "$cr_json" "$config_file"
    fi

    # Update status to Ready
    update_status "$cr_name" "$namespace" "Ready"

    log_info "Reconciliation complete for $cr_name"
}

# Ensure namespace exists
ensure_namespace() {
    local namespace="$1"

    if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
        log_info "Creating namespace: $namespace"
        kubectl create namespace "$namespace"
    else
        log_info "Namespace already exists: $namespace"
    fi
}

# Copy MySQL secret from paymenthub namespace
copy_mysql_secret() {
    local namespace="$1"
    local cr_json="$2"

    local ph_namespace
    ph_namespace=$(echo "$cr_json" | jq -r '.spec.paymenthub.namespace // "paymenthub"')

    log_info "Copying MySQL secret from $ph_namespace to $namespace..."

    # Check if mysql-secret already exists in target namespace
    if kubectl get secret mysql-secret -n "$namespace" >/dev/null 2>&1; then
        log_info "mysql-secret already exists in $namespace"
        return 0
    fi

    # Try to get operationsmysql secret (the actual name in paymenthub)
    if kubectl get secret operationsmysql -n "$ph_namespace" >/dev/null 2>&1; then
        kubectl get secret operationsmysql -n "$ph_namespace" -o json | \
            jq --arg ns "$namespace" '
                .metadata.namespace = $ns |
                .metadata.name = "mysql-secret" |
                .data.password = .data["mysql-root-password"] |
                del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp)
            ' | \
            kubectl apply -f -
        log_info "Copied operationsmysql secret as mysql-secret"
        return 0
    fi

    # Fallback: try mysql-secret
    if kubectl get secret mysql-secret -n "$ph_namespace" >/dev/null 2>&1; then
        kubectl get secret mysql-secret -n "$ph_namespace" -o json | \
            jq --arg ns "$namespace" '.metadata.namespace = $ns | del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp)' | \
            kubectl apply -f -
        log_info "Copied mysql-secret"
        return 0
    fi

    log_warn "Could not find MySQL secret in $ph_namespace"
    return 1
}

# Load database data
load_database_data() {
    local cr_name="$1"
    local namespace="$2"
    local cr_json="$3"
    local config_file="$4"

    log_info "Database schema management delegated to load-mastercard-supplementary-data.sh"
    log_info "Schema is now managed by: src/utils/data-loading/load-mastercard-supplementary-data.sh"
    log_info "Run that script to create the PHEE-351 compliant schema and load test data"

    # Note: Schema creation has been removed from operator as per design decision
    # to keep schema management in a single location (the data loading script).
    # This follows the principle of having schema and data loading in one place.

    return 0
}

# Deploy connector
deploy_connector() {
    local cr_name="$1"
    local namespace="$2"
    local cr_json="$3"
    local config_file="$4"

    log_info "Deploying CBS connector..."

    # Check if localdev mode is enabled
    local localdev_enabled
    localdev_enabled=$(echo "$cr_json" | jq -r '.spec.localdev.enabled // false')

    local image_repo
    local image_tag
    local command_section=""
    local volumes_section=""
    local volumemounts_section=""
    local extra_env_section=""

    if [ "$localdev_enabled" == "true" ]; then
        log_info "Local development mode ENABLED"

        # Use JDK image for local dev
        image_repo=$(echo "$cr_json" | jq -r '.spec.localdev.image // "eclipse-temurin"')
        image_tag=$(echo "$cr_json" | jq -r '.spec.localdev.imageTag // "17"')

        local host_path
        host_path=$(echo "$cr_json" | jq -r '.spec.localdev.hostPath // env.HOME + "/ph-ee-connector-mccbs"')

        local jar_path
        jar_path=$(echo "$cr_json" | jq -r '.spec.localdev.jarPath // "/app/build/libs/ph-ee-connector-mastercard-cbs-1.0.0-SNAPSHOT.jar"')

        log_info "  Host path: $host_path"
        log_info "  JAR path: $jar_path"
        log_info "  Image: $image_repo:$image_tag"

        # Add command override to run JAR with orchestration directory in classpath
        command_section="        command: [\"java\"]
        args:
          - \"-cp\"
          - \"${jar_path}:/app/orchestration\"
          - \"org.springframework.boot.loader.launch.JarLauncher\"
          - \"--spring.profiles.active=default\"
          - \"--zeebe.client.security.plaintext=true\""

        # Add volume mount
        volumemounts_section="        volumeMounts:
        - name: local-code
          mountPath: /app"

        # Add volume definition
        volumes_section="      volumes:
      - name: local-code
        hostPath:
          path: ${host_path}
          type: Directory"
    else
        # Use built image for production
        image_repo=$(echo "$cr_json" | jq -r '.spec.image.repository // "ph-ee-connector-mastercard-cbs"')
        image_tag=$(echo "$cr_json" | jq -r '.spec.image.tag // "1.0.0"')
    fi

    # Mount cert secret if it exists (created by mastercard.sh from local cert files).
    # This is the correct approach for Docker image deployments and remote clusters.
    local cert_env_section=""
    if kubectl get secret mastercard-cbs-certs -n "$namespace" >/dev/null 2>&1; then
        log_info "Found mastercard-cbs-certs secret - mounting certs from secret (file: paths)"
        cert_env_section="        - name: MASTERCARD_SIGNING_KEY_FILE
          value: \"file:/opt/mastercard/certs/signing-key.p12\"
        - name: MASTERCARD_ENCRYPTION_CERT
          value: \"file:/opt/mastercard/certs/encryption-key.p12\"
        - name: MASTERCARD_DECRYPTION_KEY
          value: \"file:/opt/mastercard/certs/decryption-key.pem\""

        local cert_mount="        - name: mastercard-certs
          mountPath: /opt/mastercard/certs
          readOnly: true"
        local cert_volume="      - name: mastercard-certs
        secret:
          secretName: mastercard-cbs-certs"

        if [ -z "$volumemounts_section" ]; then
            volumemounts_section="        volumeMounts:
${cert_mount}"
        else
            volumemounts_section="${volumemounts_section}
${cert_mount}"
        fi

        if [ -z "$volumes_section" ]; then
            volumes_section="      volumes:
${cert_volume}"
        else
            volumes_section="${volumes_section}
${cert_volume}"
        fi
    else
        log_info "No mastercard-cbs-certs secret found - certs must be bundled in image (classpath)"
    fi

    local replicas
    replicas=$(echo "$cr_json" | jq -r '.spec.replicas // 1')
    local mastercard_api_url
    mastercard_api_url=$(echo "$cr_json" | jq -r '.spec.mastercard.apiUrl // "https://sandbox.api.mastercard.com"')
    local zeebe_gateway
    zeebe_gateway=$(echo "$cr_json" | jq -r '.spec.paymenthub.zeebeGateway // "zeebe-gateway.paymenthub.svc.cluster.local:26500"')
    local db_host
    db_host=$(echo "$cr_json" | jq -r '.spec.paymenthub.operationsDb.host // "operationsmysql.paymenthub.svc.cluster.local"')

    # Read OAuth1 and encryption settings from config file
    local mastercard_consumer_key=""
    local mastercard_partner_id=""
    local mastercard_signing_key_alias=""
    local mastercard_signing_key_password=""
    local mastercard_encryption_enabled="false"
    local mastercard_encryption_cert_password=""
    local mastercard_encryption_fingerprint=""
    local mastercard_decryption_key_alias=""
    local mastercard_decryption_key_password=""

    if [ -n "$config_file" ] && [ -f "$config_file" ]; then
        # Simple INI parser using sed/awk (crudini not available in kubectl image)
        mastercard_consumer_key=$(sed -n '/^\[mastercard-demo\]/,/^\[/p' "$config_file" | grep "^MASTERCARD_CONSUMER_KEY" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//' || echo "")
        mastercard_partner_id=$(sed -n '/^\[mastercard-demo\]/,/^\[/p' "$config_file" | grep "^MASTERCARD_PARTNER_ID" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//' || echo "mifos-paymenthub-cbs-connector")
        mastercard_signing_key_alias=$(sed -n '/^\[mastercard-demo\]/,/^\[/p' "$config_file" | grep "^MASTERCARD_SIGNING_KEY_ALIAS" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//' || echo "keyalias")
        mastercard_signing_key_password=$(sed -n '/^\[mastercard-demo\]/,/^\[/p' "$config_file" | grep "^MASTERCARD_SIGNING_KEY_PASSWORD" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//' || echo "keystorepassword")
        mastercard_encryption_enabled=$(sed -n '/^\[mastercard-demo\]/,/^\[/p' "$config_file" | grep "^MASTERCARD_ENCRYPTION_ENABLED" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//' || echo "false")
        mastercard_encryption_cert_password=$(sed -n '/^\[mastercard-demo\]/,/^\[/p' "$config_file" | grep "^MASTERCARD_ENCRYPTION_CERT_PASSWORD" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//' || echo "keystorepassword")
        mastercard_encryption_fingerprint=$(sed -n '/^\[mastercard-demo\]/,/^\[/p' "$config_file" | grep "^MASTERCARD_ENCRYPTION_FINGERPRINT" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//' || echo "")
        mastercard_decryption_key_alias=$(sed -n '/^\[mastercard-demo\]/,/^\[/p' "$config_file" | grep "^MASTERCARD_DECRYPTION_KEY_ALIAS" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//' || echo "keyalias")
        mastercard_decryption_key_password=$(sed -n '/^\[mastercard-demo\]/,/^\[/p' "$config_file" | grep "^MASTERCARD_DECRYPTION_KEY_PASSWORD" | cut -d'=' -f2- | sed 's/^ *//;s/ *$//' || echo "keystorepassword")
    fi

    kubectl apply -n "$namespace" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ph-ee-connector-mastercard-cbs
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: ph-ee-connector-mastercard-cbs
    app.kubernetes.io/instance: ${cr_name}
spec:
  replicas: ${replicas}
  selector:
    matchLabels:
      app: ph-ee-connector-mastercard-cbs
  template:
    metadata:
      labels:
        app: ph-ee-connector-mastercard-cbs
    spec:
      containers:
      - name: connector
        image: ${image_repo}:${image_tag}
${command_section}
        ports:
        - containerPort: 8080
          name: http
        env:
        - name: ZEEBE_BROKER_CONTACTPOINT
          value: "${zeebe_gateway}"
        - name: ZEEBE_CLIENT_SECURITY_PLAINTEXT
          value: "true"
        - name: MASTERCARD_API_URL
          value: "${mastercard_api_url}"
        - name: MASTERCARD_AUTH_URL
          value: "${mastercard_api_url}/oauth/token"
        - name: MASTERCARD_PARTNER_ID
          value: "${mastercard_partner_id}"
        - name: MASTERCARD_CONSUMER_KEY
          value: "${mastercard_consumer_key}"
        - name: MASTERCARD_SIGNING_KEY_ALIAS
          value: "${mastercard_signing_key_alias}"
        - name: MASTERCARD_SIGNING_KEY_PASSWORD
          value: "${mastercard_signing_key_password}"
        - name: MASTERCARD_ENCRYPTION_ENABLED
          value: "${mastercard_encryption_enabled}"
        - name: MASTERCARD_ENCRYPTION_CERT_PASSWORD
          value: "${mastercard_encryption_cert_password}"
        - name: MASTERCARD_ENCRYPTION_FINGERPRINT
          value: "${mastercard_encryption_fingerprint}"
        - name: MASTERCARD_DECRYPTION_KEY_ALIAS
          value: "${mastercard_decryption_key_alias}"
        - name: MASTERCARD_DECRYPTION_KEY_PASSWORD
          value: "${mastercard_decryption_key_password}"
        - name: DATASOURCE_URL
          value: "jdbc:mysql://${db_host}:3306/operations"
        - name: DATASOURCE_USERNAME
          value: "root"
        - name: DATASOURCE_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-secret
              key: password
${cert_env_section}
${volumemounts_section}
        resources:
          limits:
            cpu: "500m"
            memory: "512Mi"
          requests:
            cpu: "250m"
            memory: "256Mi"
${volumes_section}
---
apiVersion: v1
kind: Service
metadata:
  name: ph-ee-connector-mastercard-cbs
  namespace: ${namespace}
spec:
  selector:
    app: ph-ee-connector-mastercard-cbs
  ports:
  - port: 8080
    targetPort: 8080
    name: http
  type: ClusterIP
EOF

    log_info "Connector deployed successfully"
}

# Deploy BPMN workflow
deploy_workflow() {
    local cr_name="$1"
    local namespace="$2"
    local cr_json="$3"
    local config_file="$4"

    log_info "Deploying BPMN workflows to Zeebe for all tenants..."

    # Read MASTERCARD_CBS_HOME from config (defaults to connector repo location)
    local mastercard_cbs_home=$(read_config_value "MASTERCARD_CBS_HOME" "$HOME/ph-ee-connector-mccbs" "$config_file")
    local mifos_gazelle_home=$(read_config_value "MIFOS_GAZELLE_HOME" "$HOME/mifos-gazelle" "$config_file")

    local workflow_template="$mastercard_cbs_home/orchestration/MastercardFundTransfer-DFSPID.bpmn"
    local deploy_script="$mifos_gazelle_home/src/utils/deployBpmn-gazelle.sh"

    # Deploy using deployBpmn-gazelle.sh script (it handles multiple tenants)
    if [ -f "$deploy_script" ]; then
        log_info "Deploying workflow using deployBpmn-gazelle.sh (handles all tenants)..."
        "$deploy_script" -c "$config_file" -f "$workflow_template" || {
            log_warn "Failed to deploy workflow"
            return 1
        }
    else
        log_warn "deployBpmn-gazelle.sh not found at $deploy_script"
        log_warn "Deploy manually: deployBpmn-gazelle.sh -c $config_file -f $workflow_template"
        return 1
    fi

    log_info "Workflow deployment complete"
}

# Cleanup resources
cleanup_resources() {
    local cr_name="$1"
    local namespace="$2"

    log_info "Cleaning up resources for $cr_name in $namespace..."

    # Delete Kubernetes resources
    kubectl delete deployment ph-ee-connector-mastercard-cbs -n "$namespace" --ignore-not-found=true
    kubectl delete service ph-ee-connector-mastercard-cbs -n "$namespace" --ignore-not-found=true
    kubectl delete job ${cr_name}-data-loader -n "$namespace" --ignore-not-found=true

    # Remove BPMN workflows from Zeebe
    cleanup_workflows

    log_info "Cleanup complete"
}

# Cleanup BPMN workflows from Zeebe
cleanup_workflows() {
    log_info "Cleaning up BPMN workflows from Zeebe..."

    # Check if zbctl is available
    if ! command -v zbctl >/dev/null 2>&1; then
        log_warn "zbctl not found - cannot remove workflows automatically"
        log_warn "Manually delete workflows if needed using Zeebe Operate UI or zbctl"
        return 0
    fi

    # List of workflow IDs to delete (tenant-specific)
    local workflow_ids=(
        "MastercardFundTransfer-greenbank"
        "MastercardFundTransfer-redbank"
        "MastercardFundTransfer-bluebank"
    )

    for workflow_id in "${workflow_ids[@]}"; do
        log_info "Checking for workflow: $workflow_id"

        # Note: zbctl doesn't have a direct delete command
        # Workflows can only be "cancelled" for running instances
        # Process definitions remain in Zeebe history
        log_warn "Zeebe does not support deleting process definitions"
        log_warn "Workflow $workflow_id will remain in Zeebe (no active instances will be affected)"
    done

    log_info "Workflow cleanup notes logged - see Zeebe Operate for manual cleanup if needed"
}

# Update CR status
update_status() {
    local cr_name="$1"
    local namespace="$2"
    local phase="$3"

    log_info "Updating status to: $phase"

    kubectl patch mastercardcbsconnector "$cr_name" -n "$namespace" --type=merge --subresource=status -p "{\"status\":{\"phase\":\"$phase\"}}" || true
}

# Watch for CR changes (simple polling for now)
watch_resources() {
    local config_file="$1"
    log_info "Starting operator controller..."
    log_info "Using config file: $config_file"

    while true; do
        # Get all MastercardCBSConnector CRs
        local crs
        crs=$(kubectl get mastercardcbsconnector --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')

        # Reconcile each CR
        echo "$crs" | jq -r '.items[] | "\(.metadata.name)|\(.metadata.namespace)"' | while IFS='|' read -r name ns; do
            reconcile "$name" "$ns" "$config_file" || log_error "Failed to reconcile $name in $ns"
        done

        # Sleep before next reconciliation loop
        sleep 30
    done
}

# Main entry point
main() {
    # Default config file location
    local config_file="${HOME}/mifos-gazelle/config/config.ini"

    # Parse command-line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                config_file="$2"
                shift 2
                ;;
            -h|--help)
                echo "Usage: $0 [-c|--config CONFIG_FILE]"
                echo ""
                echo "Options:"
                echo "  -c, --config FILE    Path to config INI file (default: ~/mifos-gazelle/config/config.ini)"
                echo "  -h, --help          Show this help message"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use -h or --help for usage information"
                exit 1
                ;;
        esac
    done

    # Validate config file exists
    if [ ! -f "$config_file" ]; then
        log_error "Config file not found: $config_file"
        log_error ""
        log_error "The default config file location is: ~/mifos-gazelle/config/config.ini"
        log_error "If your config file is in a different location, use the -c flag:"
        log_error "  $0 -c /path/to/your/config.ini"
        log_error ""
        log_error "Example: $0 -c /home/user/custom-config.ini"
        exit 1
    fi

    log_info "Mastercard CBS Operator starting..."
    log_info "Config file: $config_file"

    # Check prerequisites
    if ! command -v kubectl >/dev/null 2>&1; then
        log_error "kubectl not found"
        exit 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq not found"
        exit 1
    fi

    # Start watching
    watch_resources "$config_file"
}

# Run main if executed directly
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    main "$@"
fi
