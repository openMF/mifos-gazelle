#!/bin/bash
# newphee Operator — Reconciliation Controller

set -e

log_info()  { echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $*"; }
log_warn()  { echo "[$(date +'%Y-%m-%d %H:%M:%S')] WARN: $*" >&2; }
log_error() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

reconcile() {
    local cr_name="$1"
    local namespace="$2"
    local config_file="$3"

    log_info "Reconciling NewPhee: $cr_name in namespace: $namespace"

    local cr_json
    cr_json=$(kubectl get newphee "$cr_name" -n "$namespace" -o json 2>/dev/null || echo "{}")

    if [ "$cr_json" == "{}" ]; then
        log_warn "CR $cr_name not found in namespace $namespace"
        return 1
    fi

    local enabled
    enabled=$(echo "$cr_json" | jq -r '.spec.enabled // false')

    if [ "$enabled" != "true" ]; then
        log_info "NewPhee is disabled — cleaning up resources"
        cleanup_resources "$cr_name" "$namespace"
        update_status "$cr_name" "$namespace" "Disabled"
        return 0
    fi

    update_status "$cr_name" "$namespace" "Initializing"

    ensure_namespace "$namespace"

    deploy_component "$cr_name" "$namespace" "$cr_json" "$config_file"

    update_status "$cr_name" "$namespace" "Ready"
    log_info "Reconciliation complete for $cr_name"
}

ensure_namespace() {
    local namespace="$1"

    if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
        log_info "Creating namespace: $namespace"
        kubectl create namespace "$namespace"
    else
        log_info "Namespace already exists: $namespace"
    fi
}

deploy_component() {
    local cr_name="$1"
    local namespace="$2"
    local cr_json="$3"
    local config_file="$4"

    log_info "Deploying newphee component..."

    local image_repo
    image_repo=$(echo "$cr_json" | jq -r '.spec.image.repository // "newphee"')
    local image_tag
    image_tag=$(echo "$cr_json" | jq -r '.spec.image.tag // "latest"')
    local replicas
    replicas=$(echo "$cr_json" | jq -r '.spec.replicas // 1')

    local zeebe_gateway
    zeebe_gateway=$(echo "$cr_json" | jq -r '.spec.zeebeGateway // "zeebe-gateway.paymenthub.svc.cluster.local:26500"')

    kubectl apply -n "$namespace" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: newphee
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: newphee
    app.kubernetes.io/instance: ${cr_name}
spec:
  replicas: ${replicas}
  selector:
    matchLabels:
      app: newphee
  template:
    metadata:
      labels:
        app: newphee
    spec:
      containers:
      - name: newphee
        image: ${image_repo}:${image_tag}
        ports:
        - containerPort: 8080
          name: http
        env:
        - name: ZEEBE_BROKER_CONTACTPOINT
          value: "${zeebe_gateway}"
        - name: ZEEBE_CLIENT_SECURITY_PLAINTEXT
          value: "true"
        resources:
          limits:
            cpu: "500m"
            memory: "512Mi"
          requests:
            cpu: "250m"
            memory: "256Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: newphee
  namespace: ${namespace}
spec:
  selector:
    app: newphee
  ports:
  - port: 8080
    targetPort: 8080
    name: http
  type: ClusterIP
EOF

    log_info "newphee component deployed"
}

cleanup_resources() {
    local cr_name="$1"
    local namespace="$2"

    log_info "Cleaning up resources for $cr_name in $namespace..."
    kubectl delete deployment newphee -n "$namespace" --ignore-not-found=true
    kubectl delete service newphee -n "$namespace" --ignore-not-found=true
    log_info "Cleanup complete"
}

update_status() {
    local cr_name="$1"
    local namespace="$2"
    local phase="$3"

    log_info "Updating status to: $phase"
    kubectl patch newphee "$cr_name" -n "$namespace" \
        --type=merge --subresource=status \
        -p "{\"status\":{\"phase\":\"$phase\"}}" || true
}

watch_resources() {
    local config_file="$1"
    log_info "Starting newphee operator controller..."
    log_info "Using config file: $config_file"

    while true; do
        local crs
        crs=$(kubectl get newphee --all-namespaces -o json 2>/dev/null || echo '{"items":[]}')

        echo "$crs" | jq -r '.items[] | "\(.metadata.name)|\(.metadata.namespace)"' | \
        while IFS='|' read -r name ns; do
            reconcile "$name" "$ns" "$config_file" || log_error "Failed to reconcile $name in $ns"
        done

        sleep 30
    done
}

main() {
    local config_file="${HOME}/mifos-gazelle/config/config.ini"

    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                config_file="$2"
                shift 2
                ;;
            -h|--help)
                echo "Usage: $0 [-c|--config CONFIG_FILE]"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    if [ ! -f "$config_file" ]; then
        log_error "Config file not found: $config_file"
        log_error "Use -c flag: $0 -c /path/to/config.ini"
        exit 1
    fi

    if ! command -v kubectl >/dev/null 2>&1; then
        log_error "kubectl not found"
        exit 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq not found"
        exit 1
    fi

    log_info "newphee Operator starting..."
    watch_resources "$config_file"
}

if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    main "$@"
fi
