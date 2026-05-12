#!/bin/bash
# Deploy newphee Operator

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPERATOR_DIR="$SCRIPT_DIR"

DEFAULT_CONFIG_FILE="$HOME/mifos-gazelle/config/config.ini"
CONFIG_FILE="$DEFAULT_CONFIG_FILE"
COMMAND=""

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
                COMMAND="$1"
                shift
                ;;
            *)
                shift
                ;;
        esac
    done
}

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS] {deploy|undeploy|status}

Deploy and manage the newphee Operator.

Options:
  -c, --config FILE    Path to config INI file (default: ~/mifos-gazelle/config/config.ini)
  -h, --help           Show this help message

Commands:
  deploy    Deploy the operator (default)
  undeploy  Remove the operator
  status    Show operator and CR status

Examples:
  $0 deploy
  $0 -c ~/myconfig.ini deploy
  $0 undeploy
  $0 status

EOF
}

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

read_config_value() {
    local key="$1"
    local default="$2"
    local value

    if [ -f "$CONFIG_FILE" ]; then
        value=$(grep -E "^${key}\s*=" "$CONFIG_FILE" 2>/dev/null | cut -d '=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        value=$(eval echo "$value" 2>/dev/null || echo "$value")
    fi

    echo "${value:-$default}"
}

deploy_crd() {
    echo "Installing newphee CRD..."
    kubectl apply --validate=false -f "$OPERATOR_DIR/config/crd/newphee.yaml"

    echo "Waiting for CRD to be established..."
    kubectl wait --for condition=established --timeout=60s crd/newphees.paymenthub.mifos.io
    echo "✓ CRD installed"
}

deploy_rbac() {
    echo "Creating RBAC resources..."

    kubectl create namespace newphee --dry-run=client -o yaml | kubectl apply -f -

    kubectl apply -f "$OPERATOR_DIR/config/rbac/service_account.yaml"
    kubectl apply -f "$OPERATOR_DIR/config/rbac/role.yaml"
    kubectl apply -f "$OPERATOR_DIR/config/rbac/role_binding.yaml"

    echo "✓ RBAC configured"
}

deploy_controller() {
    echo "Deploying newphee operator controller..."

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "ERROR: Config file not found: $CONFIG_FILE"
        echo ""
        echo "Default location: $DEFAULT_CONFIG_FILE"
        echo "Use -c flag: $0 -c /path/to/config.ini deploy"
        exit 1
    fi

    echo "Using config file: $CONFIG_FILE"

    local newphee_namespace
    newphee_namespace=$(read_config_value "NEWPHEE_NAMESPACE" "newphee")

    kubectl create configmap newphee-operator-scripts \
        --from-file="$OPERATOR_DIR/controllers/reconcile.sh" \
        -n "$newphee_namespace" \
        --dry-run=client -o yaml | kubectl apply -f -

    kubectl create configmap newphee-operator-config \
        --from-file="config.ini=${CONFIG_FILE}" \
        -n "$newphee_namespace" \
        --dry-run=client -o yaml | kubectl apply -f -

    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: newphee-operator
  namespace: ${newphee_namespace}
  labels:
    app.kubernetes.io/name: newphee-operator
spec:
  replicas: 1
  selector:
    matchLabels:
      app: newphee-operator
  template:
    metadata:
      labels:
        app: newphee-operator
    spec:
      serviceAccountName: newphee-operator
      containers:
      - name: operator
        image: bitnami/kubectl:latest
        imagePullPolicy: IfNotPresent
        command:
          - /bin/bash
          - /scripts/reconcile.sh
          - -c
          - /etc/gazelle/config.ini
        env:
        - name: HOME
          value: /tmp
        volumeMounts:
        - name: scripts
          mountPath: /scripts
        - name: config
          mountPath: /etc/gazelle
          readOnly: true
        resources:
          limits:
            cpu: "100m"
            memory: "256Mi"
          requests:
            cpu: "10m"
            memory: "128Mi"
      volumes:
      - name: scripts
        configMap:
          name: newphee-operator-scripts
          defaultMode: 0755
      - name: config
        configMap:
          name: newphee-operator-config
EOF

    echo "✓ Controller deployed"
}

verify_deployment() {
    echo ""
    echo "Verifying deployment..."

    kubectl get crd newphees.paymenthub.mifos.io || {
        echo "✗ CRD not found"
        return 1
    }

    local newphee_namespace
    newphee_namespace=$(read_config_value "NEWPHEE_NAMESPACE" "newphee")

    kubectl rollout status deployment/newphee-operator -n "$newphee_namespace" --timeout=120s || {
        echo "✗ Operator pod not ready"
        kubectl get pods -l app=newphee-operator -n "$newphee_namespace"
        kubectl describe pods -l app=newphee-operator -n "$newphee_namespace" | grep -A20 "Events:"
        kubectl logs -l app=newphee-operator -n "$newphee_namespace" --tail=30 2>/dev/null || true
        return 1
    }

    echo "✓ Operator is running"
}

main() {
    echo "======================================"
    echo "Deploying newphee Operator"
    echo "======================================"

    if ! command -v kubectl >/dev/null 2>&1; then
        echo "ERROR: kubectl not found"
        exit 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR: jq not found"
        exit 1
    fi

    deploy_crd
    deploy_rbac
    deploy_controller
    verify_deployment

    local newphee_namespace
    newphee_namespace=$(read_config_value "NEWPHEE_NAMESPACE" "newphee")

    echo ""
    echo "======================================"
    echo "✅ newphee Operator deployed successfully"
    echo "======================================"
    echo ""
    echo "Next steps:"
    echo "  1. Apply a NewPhee resource:"
    echo "     kubectl apply -f $OPERATOR_DIR/config/samples/newphee-default.yaml"
    echo ""
    echo "  2. Check status:"
    echo "     kubectl get newphees -n $newphee_namespace"
    echo ""
    echo "  3. View operator logs:"
    echo "     kubectl logs -l app=newphee-operator -n $newphee_namespace -f"
    echo ""
}

parse_args "$@"
CONFIG_FILE=$(expand_tilde "$CONFIG_FILE")
COMMAND="${COMMAND:-deploy}"

case "$COMMAND" in
    deploy)
        main
        ;;
    undeploy)
        echo "Undeploying newphee operator..."
        NEWPHEE_NS=$(read_config_value "NEWPHEE_NAMESPACE" "newphee")
        kubectl delete deployment newphee-operator -n "$NEWPHEE_NS" --ignore-not-found=true
        kubectl delete configmap newphee-operator-scripts newphee-operator-config -n "$NEWPHEE_NS" --ignore-not-found=true
        kubectl delete -f "$OPERATOR_DIR/config/rbac/role_binding.yaml" --ignore-not-found=true
        kubectl delete -f "$OPERATOR_DIR/config/rbac/role.yaml" --ignore-not-found=true
        kubectl delete -f "$OPERATOR_DIR/config/rbac/service_account.yaml" --ignore-not-found=true
        echo "Note: CRD and CRs are preserved. To fully remove:"
        echo "  kubectl delete newphees --all --all-namespaces"
        echo "  kubectl delete crd newphees.paymenthub.mifos.io"
        ;;
    status)
        NEWPHEE_NS=$(read_config_value "NEWPHEE_NAMESPACE" "newphee")
        echo "Operator status:"
        kubectl get deployment newphee-operator -n "$NEWPHEE_NS" 2>/dev/null || echo "Operator not deployed"
        echo ""
        echo "NewPhee resources:"
        kubectl get newphees --all-namespaces 2>/dev/null || echo "No NewPhee CRs found"
        ;;
    *)
        show_help
        exit 1
        ;;
esac
