#!/usr/bin/env bash
# OpenSPP deployment script for Mifos-Gazelle.
# Deploys OpenSPP2 (Odoo 19 + PostGIS 18) from the Gazelle-owned Helm chart
# at src/deployer/helm/openspp/. OpenSPP is self-contained (brings its own PostGIS DB),
# so it does NOT depend on the shared infra chart.

# Do NOT use 'set -e': this script is sourced by deployer.sh and would affect the parent shell.
# Do NOT source commandline.sh here (circular dependency). Config values (OPENSPP_*) and the
# logging helpers (log_section/log_step/log_ok/log_banner/log_with_verbose_check, INFO/WARNING/DEBUG)
# are already in the environment when deployer.sh sources this file.

# Expand a leading ~ to the user's home directory.
expand_tilde() {
    local path="$1"
    if [[ "$path" == "~"* ]]; then
        path="${HOME}${path:1}"
    fi
    echo "$path"
}

# Resolve a password: a host file path wins (mastercard.sh pattern, for prod/remote), else a known
# local-dev default, else a random value. $1 = file path (may be empty), $2 = dev default (optional).
# A fixed default also keeps redeploys idempotent: a random db password would not match the one
# PostGIS already persisted in its PVC.
openspp_resolve_secret() {
    local path default
    path=$(expand_tilde "${1:-}")
    default="${2:-}"
    if [ -n "$path" ] && [ -f "$path" ]; then
        tr -d '\n' < "$path"
    elif [ -n "$default" ]; then
        echo "$default"
    elif command -v openssl &> /dev/null; then
        openssl rand -hex 16
    else
        date +%s | sha256sum | head -c 32
    fi
}

openspp_check_prerequisites() {
    OPENSPP_NAMESPACE="${OPENSPP_NAMESPACE:-openspp}"
    OPENSPP_RELEASE_NAME="${OPENSPP_RELEASE_NAME:-openspp}"
    OPENSPP_IMAGE_REPOSITORY="${OPENSPP_IMAGE_REPOSITORY:-ghcr.io/openmf/openspp}"
    OPENSPP_IMAGE_TAG="${OPENSPP_IMAGE_TAG:-19.0}"

    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install kubectl (or run setup-env.sh first)."
        exit 1
    fi
    if ! command -v helm &> /dev/null; then
        log_error "helm not found. Please install helm (or run setup-env.sh first)."
        exit 1
    fi
    if ! kubectl get nodes &> /dev/null; then
        log_error "Kubernetes cluster not reachable. Start k3s / run: sudo ./setup-env.sh"
        exit 1
    fi
    # Build-only image: must be preloaded in the cluster (not published to a registry yet).
    # Fail fast here instead of hanging on an ImagePullBackOff during pod startup.
    if ! kubectl get nodes -o jsonpath='{.items[*].status.images[*].names[*]}' 2>/dev/null \
        | tr ' ' '\n' | grep -qx "${OPENSPP_IMAGE_REPOSITORY}:${OPENSPP_IMAGE_TAG}"; then
        log_error "Image ${OPENSPP_IMAGE_REPOSITORY}:${OPENSPP_IMAGE_TAG} not found in the cluster (build-only)."
        log_error "Import it and redeploy:  docker save ${OPENSPP_IMAGE_REPOSITORY}:${OPENSPP_IMAGE_TAG} | sudo k3s ctr images import -"
        exit 1
    fi
    log_with_verbose_check "$debug" "$INFO" "Using image ${OPENSPP_IMAGE_REPOSITORY}:${OPENSPP_IMAGE_TAG}"
}

# Deploy the Helm chart with helm upgrade --install (idempotent) and WITHOUT --wait.
# OpenSPP2 has no init Job (the container self-initialises), so we let helm create the resources
# and then wait for the Deployment to become Ready separately (openspp_wait_ready).
openspp_deploy_chart() {
    local chart_dir="$RUN_DIR/src/deployer/helm/openspp"
    if [ ! -d "$chart_dir" ]; then
        log_error "OpenSPP chart not found: $chart_dir"
        exit 1
    fi

    # OpenSPP2 has no separate master password: the admin password is also the DB-management one.
    # Local-dev defaults (admin/admin = upstream OpenSPP2 default); override via the *_FILE paths.
    local db_pw admin_pw
    db_pw=$(openspp_resolve_secret "${OPENSPP_DB_PASSWORD_FILE:-}" "openspp")
    admin_pw=$(openspp_resolve_secret "${OPENSPP_ADMIN_PASSWORD_FILE:-}" "admin")

    local helm_args=(
        upgrade --install "$OPENSPP_RELEASE_NAME" "$chart_dir"
        -n "$OPENSPP_NAMESPACE" --create-namespace
        --timeout "${startup_timeout:-900}s"
        --set "odoo.image.repository=${OPENSPP_IMAGE_REPOSITORY}"
        --set "odoo.image.tag=${OPENSPP_IMAGE_TAG}"
        --set "secrets.dbPassword=${db_pw}"
        --set "secrets.odooAdminPassword=${admin_pw}"
    )

    if [[ "$debug" == "true" ]]; then
        helm "${helm_args[@]}"
    else
        helm "${helm_args[@]}" > /dev/null 2>&1
    fi
    local rc=$?
    if [ $rc -ne 0 ]; then
        log_error "helm upgrade --install failed for release '$OPENSPP_RELEASE_NAME' (exit $rc)."
        exit 1
    fi
}

openspp_wait_ready() {
    # PostGIS first, then Odoo. Odoo self-initialises on first boot (installs base + the module),
    # gated behind its startupProbe, so this rollout wait can take a few minutes on a clean install.
    kubectl rollout status statefulset/openspp-postgis -n "$OPENSPP_NAMESPACE" --timeout=180s > /dev/null 2>&1
    if ! kubectl rollout status deployment/openspp-odoo -n "$OPENSPP_NAMESPACE" --timeout=300s > /dev/null 2>&1; then
        # Most common cause: the build-only image isn't in the cluster yet.
        if kubectl get pods -n "$OPENSPP_NAMESPACE" \
            -o jsonpath='{.items[*].status.containerStatuses[*].state.waiting.reason}' 2>/dev/null \
            | grep -q 'ImagePullBackOff\|ErrImagePull'; then
            log_error "Image ${OPENSPP_IMAGE_REPOSITORY}:${OPENSPP_IMAGE_TAG} not found in the cluster."
            log_error "It is build-only; import it:  docker save ${OPENSPP_IMAGE_REPOSITORY}:${OPENSPP_IMAGE_TAG} | sudo k3s ctr images import -"
        fi
        return 1
    fi
    return 0
}

# Smoke test: /web/login must return 200 AND the OpenSPP module must be installed.
openspp_verify() {
    local local_port=18069
    kubectl port-forward "svc/openspp-odoo" "${local_port}:8069" -n "$OPENSPP_NAMESPACE" > /dev/null 2>&1 &
    local pf_pid=$!
    sleep 5

    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${local_port}/web/login" 2>/dev/null)
    kill "$pf_pid" > /dev/null 2>&1

    if [ "$code" != "200" ]; then
        log_warn "Smoke test: /web/login returned HTTP '${code}' (expected 200). Check the Odoo pod logs."
        return 1
    fi

    # /web/login returns 200 even on an empty Odoo, so confirm the module is really installed.
    local installed
    installed=$(kubectl exec -n "$OPENSPP_NAMESPACE" "${OPENSPP_RELEASE_NAME:-openspp}-postgis-0" -- \
        psql -U odoo -d openspp -tAc \
        "SELECT 1 FROM ir_module_module WHERE name = 'spp_base_common' AND state = 'installed'" \
        2>/dev/null | tr -d '[:space:]')
    if [ "$installed" != "1" ]; then
        log_warn "Smoke test: OpenSPP module not installed (Odoo is empty). Check the Odoo pod logs."
        return 1
    fi

    log_with_verbose_check "$debug" "$INFO" "Smoke test OK: /web/login 200 and OpenSPP module installed"
    return 0
}

cleanup_openspp() {
    OPENSPP_NAMESPACE="${OPENSPP_NAMESPACE:-openspp}"
    OPENSPP_RELEASE_NAME="${OPENSPP_RELEASE_NAME:-openspp}"

    helm uninstall "$OPENSPP_RELEASE_NAME" -n "$OPENSPP_NAMESPACE" > /dev/null 2>&1
    kubectl delete namespace "$OPENSPP_NAMESPACE" --ignore-not-found=true > /dev/null 2>&1
}

deploy_openspp() {
    log_section "Deploying OpenSPP"
    openspp_check_prerequisites
    log_with_verbose_check "$debug" "$DEBUG" "Namespace: $OPENSPP_NAMESPACE  Release: $OPENSPP_RELEASE_NAME"

    log_step "Deploying OpenSPP Helm chart (installs modules on first boot; this can take a few minutes)"
    openspp_deploy_chart
    log_ok

    log_step "Waiting for PostGIS and Odoo to become Ready"
    if ! openspp_wait_ready; then
        log_failed "OpenSPP did not become Ready"
        exit 1
    fi
    log_ok

    log_step "Smoke test (/web/login + OpenSPP module)"
    if ! openspp_verify; then
        log_failed "OpenSPP smoke test"
        exit 1
    fi
    log_ok

    log_banner "OpenSPP Deployed"
    echo "  Namespace: $OPENSPP_NAMESPACE"
    echo "  Access:    kubectl port-forward svc/openspp-odoo 8069:8069 -n $OPENSPP_NAMESPACE"
    echo "             then open http://127.0.0.1:8069/web/login"
    echo
}

# Main entry point (only used when the script is executed directly, not sourced).
main() {
    set -e
    debug="${debug:-false}"
    case "${1:-deploy}" in
        deploy)
            deploy_openspp
            ;;
        undeploy|cleanup)
            cleanup_openspp
            ;;
        verify)
            debug="true"
            openspp_verify
            ;;
        status)
            kubectl get all,pvc -n "${OPENSPP_NAMESPACE:-openspp}"
            ;;
        *)
            echo "Usage: $0 {deploy|undeploy|verify|status}"
            exit 1
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    main "$@"
fi
