#!/bin/bash
# Deploy Mastercard CBS Operator

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPERATOR_DIR="$SCRIPT_DIR"

# Default config file location
DEFAULT_CONFIG_FILE="$HOME/mifos-gazelle/config/config.ini"
CONFIG_FILE="$DEFAULT_CONFIG_FILE"

# Parse command line arguments (before main case statement)
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            deploy|undeploy|status)
                # These are handled by the main case statement
                COMMAND="$1"
                shift
                ;;
            *)
                # Unknown option, pass through
                shift
                ;;
        esac
    done
}

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS] {deploy|undeploy|status}

Deploy and manage the Mastercard CBS Operator.

Options:
  -c, --config FILE    Path to config INI file (default: ~/mifos-gazelle/config/config.ini)
  -h, --help           Show this help message

Commands:
  deploy    Deploy the operator (default)
  undeploy  Remove the operator
  status    Show operator status

Examples:
  $0 deploy                              # Deploy with default config
  $0 -c ~/tomconfig.ini deploy           # Deploy with custom config
  $0 -c /path/to/config.ini deploy       # Deploy with specific config file
  $0 undeploy                            # Remove operator

EOF
}

# Expand ~ to the actual user's home directory (handles sudo)
expand_tilde() {
    local path="$1"
    if [[ "$path" == "~"* ]]; then
        # When running under sudo, use SUDO_USER's home, otherwise use HOME
        local user_home
        if [ -n "$SUDO_USER" ]; then
            user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        else
            user_home="$HOME"
        fi
        # Replace leading ~ with the home directory
        path="${user_home}${path:1}"
    fi
    echo "$path"
}

# Read a value from the config file
read_config_value() {
    local key="$1"
    local default="$2"
    local value

    if [ -f "$CONFIG_FILE" ]; then
        # Extract value, handling spaces and expanding $HOME
        value=$(grep -E "^${key}\s*=" "$CONFIG_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        # Expand $HOME and ~ in the value
        value=$(eval echo "$value" 2>/dev/null || echo "$value")
    fi

    echo "${value:-$default}"
}

# Function to deploy CRD
deploy_crd() {
    echo "Installing Custom Resource Definition..."
    kubectl apply --validate=false -f "$OPERATOR_DIR/config/crd/mastercard-cbs-connector.yaml"

    echo "Waiting for CRD to be established..."
    kubectl wait --for condition=established --timeout=60s crd/mastercardcbsconnectors.paymenthub.mifos.io
    echo "✓ CRD installed"
}

# Function to deploy RBAC
deploy_rbac() {
    echo "Creating RBAC resources..."

    # Create namespace if it doesn't exist
    kubectl create namespace mastercard-demo --dry-run=client -o yaml | kubectl apply -f -

    # Deploy service account, role, and role binding
    kubectl apply -f "$OPERATOR_DIR/config/rbac/service_account.yaml"
    kubectl apply -f "$OPERATOR_DIR/config/rbac/role.yaml"
    kubectl apply -f "$OPERATOR_DIR/config/rbac/role_binding.yaml"

    echo "✓ RBAC configured"
}

# Function to deploy operator controller
deploy_controller() {
    echo "Deploying operator controller..."

    # Validate config file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "ERROR: Config file not found: $CONFIG_FILE"
        echo ""
        echo "The default config file location is: $DEFAULT_CONFIG_FILE"
        echo "Use -c flag to specify a different config file:"
        echo "  $0 -c /path/to/config.ini deploy"
        exit 1
    fi

    echo "Using config file: $CONFIG_FILE"

    # Read values from config file
    local mastercard_cbs_home
    mastercard_cbs_home=$(read_config_value "MASTERCARD_CBS_HOME" "$HOME/ph-ee-connector-mccbs")
    echo "  MASTERCARD_CBS_HOME: $mastercard_cbs_home"

    # Get the directory containing the config file (to mount it at same path in container)
    local config_dir
    config_dir=$(dirname "$CONFIG_FILE")

    # Get UID of config file owner (needed for container to read host directory with 750 permissions)
    local config_uid
    config_uid=$(stat -c %u "$CONFIG_FILE" 2>/dev/null || echo "1000")

    echo "  Config directory: $config_dir"
    echo "  Config file path (used in container): $CONFIG_FILE"
    echo "  Config file owner UID: $config_uid"

    # Create ConfigMap with reconcile script
    kubectl create configmap mastercard-operator-scripts \
        --from-file="$OPERATOR_DIR/controllers/reconcile.sh" \
        -n mastercard-demo \
        --dry-run=client -o yaml | kubectl apply -f -

    # Deploy controller as a Deployment
    # Note: Mount config directory at the SAME path as on host so paths work consistently
    # Note: Run as same UID as config file owner to access home directory (typically 750 permissions)
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mastercard-cbs-operator
  namespace: mastercard-demo
  labels:
    app.kubernetes.io/name: mastercard-cbs-operator
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mastercard-cbs-operator
  template:
    metadata:
      labels:
        app: mastercard-cbs-operator
    spec:
      serviceAccountName: mastercard-cbs-operator
      securityContext:
        runAsUser: ${config_uid}
        runAsGroup: ${config_uid}
        fsGroup: ${config_uid}
      containers:
      - name: operator
        image: bitnami/kubectl:latest
        command:
          - /bin/bash
          - /scripts/reconcile.sh
          - -c
          - ${CONFIG_FILE}
        env:
        - name: HOME
          value: /tmp
        volumeMounts:
        - name: scripts
          mountPath: /scripts
        - name: mastercard-data
          mountPath: /opt/mastercard
        - name: config
          mountPath: ${config_dir}
          readOnly: true
        resources:
          limits:
            cpu: "200m"
            memory: "256Mi"
          requests:
            cpu: "100m"
            memory: "128Mi"
      volumes:
      - name: scripts
        configMap:
          name: mastercard-operator-scripts
          defaultMode: 0755
      - name: mastercard-data
        hostPath:
          path: ${mastercard_cbs_home}
          type: Directory
      - name: config
        hostPath:
          path: ${config_dir}
          type: Directory
EOF

    echo "✓ Controller deployed"
}

# Function to verify deployment
verify_deployment() {
    echo ""
    echo "Verifying deployment..."

    echo "Checking CRD..."
    kubectl get crd mastercardcbsconnectors.paymenthub.mifos.io || {
        echo "✗ CRD not found"
        return 1
    }

    echo "Checking operator pod..."
    kubectl wait --for=condition=ready --timeout=60s pod -l app=mastercard-cbs-operator -n mastercard-demo || {
        echo "✗ Operator pod not ready"
        kubectl logs -l app=mastercard-cbs-operator -n mastercard-demo --tail=50
        return 1
    }

    echo "✓ Operator is running"
}

# Main deployment flow
main() {
    echo "======================================"
    echo "Deploying Mastercard CBS Operator"
    echo "======================================"
    deploy_crd
    deploy_rbac
    deploy_controller
    verify_deployment

    echo ""
    echo "======================================"
    echo "✅ Operator deployed successfully"
    echo "======================================"
    echo ""
    echo "Next steps:"
    echo "  1. Create a MastercardCBSConnector resource:"
    echo "     kubectl apply -f $OPERATOR_DIR/config/samples/mastercard-cbs-default.yaml"
    echo ""
    echo "  2. Check status:"
    echo "     kubectl get mastercardcbsconnectors -n mastercard-demo"
    echo ""
    echo "  3. View operator logs:"
    echo "     kubectl logs -l app=mastercard-cbs-operator -n mastercard-demo -f"
    echo ""
}

# Parse arguments first
parse_args "$@"

# Expand ~ in config file path (handles sudo correctly)
CONFIG_FILE=$(expand_tilde "$CONFIG_FILE")

# Default command to deploy if not specified
COMMAND="${COMMAND:-deploy}"

# Handle command
case "$COMMAND" in
    deploy)
        main
        ;;
    undeploy)
        echo "Undeploying operator..."
        kubectl delete deployment mastercard-cbs-operator -n mastercard-demo --ignore-not-found=true
        kubectl delete configmap mastercard-operator-scripts -n mastercard-demo --ignore-not-found=true
        kubectl delete -f "$OPERATOR_DIR/config/rbac/role_binding.yaml" --ignore-not-found=true
        kubectl delete -f "$OPERATOR_DIR/config/rbac/role.yaml" --ignore-not-found=true
        kubectl delete -f "$OPERATOR_DIR/config/rbac/service_account.yaml" --ignore-not-found=true
        echo "Note: CRD and CRs are preserved. To remove:"
        echo "  kubectl delete mastercardcbsconnectors --all --all-namespaces"
        echo "  kubectl delete crd mastercardcbsconnectors.paymenthub.mifos.io"
        ;;
    status)
        echo "Operator status:"
        kubectl get deployment mastercard-cbs-operator -n mastercard-demo || echo "Operator not deployed"
        echo ""
        echo "MastercardCBSConnector resources:"
        kubectl get mastercardcbsconnectors --all-namespaces
        ;;
    *)
        show_help
        exit 1
        ;;
esac
