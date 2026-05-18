#!/bin/bash
# OpenSPP deployment module for Mifos Gazelle
# Deploys OpenSPP Social Safety Net Platform on Kubernetes

source "$RUN_DIR/src/utils/logger.sh"
source "$RUN_DIR/src/utils/helpers.sh"

# Get OpenSPP configuration from config.ini
OPENSPP_ENABLED=$(get_config openspp enabled)
OPENSPP_NAMESPACE=$(get_config openspp namespace)
OPENSPP_REPO=$(get_config openspp repo)
OPENSPP_BRANCH=$(get_config openspp branch)
OPENSPP_VERSION=$(get_config openspp version)

function deploy_openspp() {
    log_info "Starting OpenSPP deployment..."

    # Check if OpenSPP is enabled
    if [[ "$OPENSPP_ENABLED" != "true" ]]; then
        log_info "OpenSPP is disabled in config. Skipping..."
        return 0
    fi

    # Create namespace
    log_info "Creating namespace: $OPENSPP_NAMESPACE"
    kubectl create namespace "$OPENSPP_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

    # Wait for namespace to be ready
    wait_for_namespace "$OPENSPP_NAMESPACE"

    # Create database secret (for PostgreSQL connection)
    log_info "Creating database secrets..."
    kubectl create secret generic openspp-db-secret \
        --from-literal=password="openspp" \
        --namespace="$OPENSPP_NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -

    # Create admin password secret
    log_info "Creating admin password secret..."
    kubectl create secret generic openspp-admin-secret \
        --from-literal=password="admin" \
        --namespace="$OPENSPP_NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -

    # Deploy OpenSPP using Helm chart
    log_info "Deploying OpenSPP using Helm..."
    OPENSPP_CHART_PATH="$INFRA_CHART_DIR/../openspp"

    helm upgrade --install openspp \
        "$OPENSPP_CHART_PATH" \
        --namespace "$OPENSPP_NAMESPACE" \
        --values "$OPENSPP_CHART_PATH/values.yaml" \
        --set image.tag="$OPENSPP_VERSION" \
        --wait \
        --timeout 10m

    if [[ $? -eq 0 ]]; then
        log_info "✓ OpenSPP deployed successfully"
        return 0
    else
        log_error "✗ OpenSPP deployment failed"
        return 1
    fi
}

function wait_for_openspp() {
    log_info "Waiting for OpenSPP pods to be ready..."

    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=openspp \
        --namespace="$OPENSPP_NAMESPACE" \
        --timeout=300s

    if [[ $? -eq 0 ]]; then
        log_info "✓ OpenSPP is ready"
        return 0
    else
        log_error "✗ OpenSPP pods did not become ready"
        return 1
    fi
}

function openspp_info() {
    log_info "OpenSPP Information:"
    log_info "  Namespace: $OPENSPP_NAMESPACE"
    log_info "  Service: openspp.$OPENSPP_NAMESPACE.svc.cluster.local:8069"
    log_info "  Web UI: https://openspp.mifos.gazelle.test"
    log_info "  Default Admin: admin / admin"
}

# Export functions for sourcing in deployer.sh
export -f deploy_openspp
export -f wait_for_openspp
export -f openspp_info
