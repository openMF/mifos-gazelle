#!/bin/bash

# k3s-docker-login.sh
# Configures Docker Hub authentication for Kubernetes namespaces
# Uses DOCKERHUB_USERNAME and DOCKERHUB_PASSWORD environment variables

# Exit silently if credentials not set
if [[ -z "${DOCKERHUB_USERNAME:-}" ]] || [[ -z "${DOCKERHUB_PASSWORD:-}" ]]; then
    # No credentials - skip silently
    exit 0
fi

echo "    Configuring Docker Hub authentication (user: $DOCKERHUB_USERNAME)"

# Default values
DOCKER_SERVER="docker.io"
SECRET_NAME="dockerhub-secret"
DOCKER_EMAIL="${DOCKERHUB_EMAIL:-noreply@docker.io}"

# If namespace parameter provided, use it; otherwise process all namespaces
TARGET_NAMESPACE="${1:-}"

if [[ -n "$TARGET_NAMESPACE" ]]; then
    # Single namespace mode
    NAMESPACES="$TARGET_NAMESPACE"
else
    # All namespaces mode
    NAMESPACES=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}')
fi

# Process namespaces
for NS in $NAMESPACES; do
    # Check if secret already exists
    if kubectl get secret "$SECRET_NAME" -n "$NS" &>/dev/null; then
        # Update existing secret
        kubectl delete secret "$SECRET_NAME" -n "$NS" &>/dev/null || true
    fi

    # Create the secret
    if ! kubectl create secret docker-registry "$SECRET_NAME" \
        --docker-server="$DOCKER_SERVER" \
        --docker-username="$DOCKERHUB_USERNAME" \
        --docker-password="$DOCKERHUB_PASSWORD" \
        --docker-email="$DOCKER_EMAIL" \
        -n "$NS" &>/dev/null; then
        # Failed to create secret
        echo "    ✗ Failed to configure Docker Hub auth for namespace: $NS" >&2
        continue
    fi

    # Patch ALL service accounts in this namespace to use the secret
    SA_NAMES=$(kubectl get sa -n "$NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    PATCHED_COUNT=0
    for SA in $SA_NAMES; do
        PATCH_JSON='{"imagePullSecrets": [{"name": "'"$SECRET_NAME"'"}]}'
        if kubectl patch serviceaccount "$SA" -n "$NS" -p "$PATCH_JSON" &>/dev/null; then
            ((PATCHED_COUNT++))
        fi
    done

    if [[ $PATCHED_COUNT -gt 0 ]]; then
        echo "    ✓ Docker Hub auth configured for namespace: $NS ($PATCHED_COUNT service accounts)"
    else
        echo "    ⚠ Secret created but failed to patch service accounts in namespace: $NS" >&2
    fi
done

exit 0
