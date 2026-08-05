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

# Host architecture in Kubernetes naming, used for the chart's nodeSelector.
# Same mapping as src/environmentSetup/k8s.sh. Set OPENSPP_ARCH to override, or to ""
# to deploy without a nodeSelector.
openspp_detect_arch() {
    case "$(uname -m)" in
        x86_64)        echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)             echo "" ;;
    esac
}

# True when the image is already loaded in the cluster's container runtime.
openspp_image_in_cluster() {
    kubectl get nodes -o jsonpath='{.items[*].status.images[*].names[*]}' 2>/dev/null \
        | tr ' ' '\n' | grep -qx "${OPENSPP_IMAGE_REPOSITORY}:${OPENSPP_IMAGE_TAG}"
}

# Asks the registry for the manifest only: 0 pullable, 1 not there, 2 nothing here to ask with.
# The node does the pulling, so a missing local docker is not an answer about the image.
openspp_image_pullable() {
    command -v docker &> /dev/null || return 2
    docker manifest inspect "${OPENSPP_IMAGE_REPOSITORY}:${OPENSPP_IMAGE_TAG}" &> /dev/null || return 1
}

# True when an image built here can be loaded into this cluster. The import runs 'k3s ctr' on
# this machine, so it needs a k3s cluster that lives here: a remote cluster cannot be reached
# that way, and neither can the one inside the Colima VM on macOS.
openspp_can_import_image() {
    [[ "${environment:-local}" == "remote" ]] && return 1
    command -v k3s &> /dev/null
}

# Fetch the OpenSPP2 source once. An existing checkout is reused, so a second deploy does not
# go to the network.
openspp_fetch_source() {
    if [[ -f "$OPENSPP_SOURCE_DIR/docker/Dockerfile" ]]; then
        log_with_verbose_check "$debug" "$INFO" "Using the OpenSPP2 checkout at $OPENSPP_SOURCE_DIR"
        return 0
    fi
    if ! command -v git &> /dev/null; then
        log_error "git not found, needed to fetch the OpenSPP2 source."
        return 1
    fi
    log_with_level "$INFO" "Cloning OpenSPP2 ${OPENSPP_SOURCE_REF} into $OPENSPP_SOURCE_DIR"
    mkdir -p "$(dirname "$OPENSPP_SOURCE_DIR")"
    if ! git clone --branch "$OPENSPP_SOURCE_REF" --depth 1 \
        "$OPENSPP_SOURCE_REPO" "$OPENSPP_SOURCE_DIR" > /dev/null 2>&1; then
        log_error "Could not clone $OPENSPP_SOURCE_REPO at $OPENSPP_SOURCE_REF"
        return 1
    fi
}

# Build the application image for this host and load it into the cluster, reusing the shared
# build utility. The build runs as the current user; only the import needs root.
openspp_build_image() {
    local builder="$RUN_DIR/src/utils/build-and-import-image.sh"
    if [[ ! -x "$builder" ]]; then
        log_error "Build utility not found: $builder"
        return 1
    fi

    log_with_level "$INFO" "Image ${OPENSPP_IMAGE_REPOSITORY}:${OPENSPP_IMAGE_TAG} is missing and OPENSPP_BUILD_IF_MISSING is true."
    log_with_level "$INFO" "Building it now. A cold build takes about 30 minutes and around 3 GB of disk."
    log_with_level "$INFO" "The import step runs sudo, so it may ask for your password."

    openspp_fetch_source || return 1

    # An array, not ${debug:+-v}: debug holds the string "false", which is not empty.
    local extra=()
    [[ "$debug" == "true" ]] && extra=(-v)
    "$builder" -n "$OPENSPP_IMAGE_REPOSITORY" -t "$OPENSPP_IMAGE_TAG" \
        -c "$OPENSPP_SOURCE_DIR" -f "$OPENSPP_SOURCE_DIR/docker/Dockerfile" \
        --target production "${extra[@]}"
}

# Make sure the image is available to the cluster, building it when that is the only way left.
# The three checks go from cheapest to most expensive: reading the node is free, asking the
# registry is one short request, building is about half an hour. So the usual case, where the
# image is already there, makes no network call at all.
openspp_ensure_image() {
    openspp_image_in_cluster && return 0

    local pullable=0
    openspp_image_pullable || pullable=$?
    if [[ $pullable -eq 0 ]]; then
        log_with_level "$INFO" "Image ${OPENSPP_IMAGE_REPOSITORY}:${OPENSPP_IMAGE_TAG} is not loaded but can be pulled. Letting Kubernetes pull it."
        return 0
    fi
    if [[ $pullable -eq 2 ]]; then
        log_with_level "$INFO" "Image ${OPENSPP_IMAGE_REPOSITORY}:${OPENSPP_IMAGE_TAG} is not loaded and cannot be checked from here (no docker). Letting Kubernetes pull it; an unreachable image shows up as ImagePullBackOff while waiting for the pods."
        return 0
    fi

    # The build utility reports its own failure, and that is what is trusted here. The node's
    # image list is not: it is published by the kubelet and lags, so it still says no right
    # after an import.
    if [[ "$OPENSPP_BUILD_IF_MISSING" == "true" ]] && openspp_can_import_image \
        && openspp_build_image; then
        log_with_level "$INFO" "Image ${OPENSPP_IMAGE_REPOSITORY}:${OPENSPP_IMAGE_TAG} built and imported."
        return 0
    fi

    log_error "Image ${OPENSPP_IMAGE_REPOSITORY}:${OPENSPP_IMAGE_TAG} is not in the cluster and cannot be pulled."
    if [[ "$OPENSPP_BUILD_IF_MISSING" == "true" ]] && ! openspp_can_import_image; then
        log_error "It cannot be built here either: the import needs a k3s cluster running on this machine."
        log_error "Build it and push it to a registry:  src/utils/build-and-import-image.sh -n <registry>/openspp -t ${OPENSPP_IMAGE_TAG} -c <OpenSPP2 checkout> -f <OpenSPP2 checkout>/docker/Dockerfile --target production --push"
        log_error "Or build it on the cluster node itself and import it there."
    else
        log_error "Build and import it with:  src/utils/build-and-import-image.sh -n ${OPENSPP_IMAGE_REPOSITORY} -t ${OPENSPP_IMAGE_TAG} -c <OpenSPP2 checkout> -f <OpenSPP2 checkout>/docker/Dockerfile --target production"
        log_error "Or import an image you already built:  docker save ${OPENSPP_IMAGE_REPOSITORY}:${OPENSPP_IMAGE_TAG} | sudo k3s ctr images import -"
        if [[ "$OPENSPP_BUILD_IF_MISSING" != "true" ]]; then
            log_error "Set OPENSPP_BUILD_IF_MISSING = true in config.ini [openspp] to build it automatically."
        fi
    fi
    exit 1
}

openspp_check_prerequisites() {
    OPENSPP_NAMESPACE="${OPENSPP_NAMESPACE:-openspp}"
    OPENSPP_RELEASE_NAME="${OPENSPP_RELEASE_NAME:-openspp}"
    OPENSPP_IMAGE_REPOSITORY="${OPENSPP_IMAGE_REPOSITORY:-ghcr.io/openmf/openspp}"
    OPENSPP_IMAGE_TAG="${OPENSPP_IMAGE_TAG:-19.0}"
    OPENSPP_ARCH="${OPENSPP_ARCH-$(openspp_detect_arch)}"
    OPENSPP_POSTGIS_REPOSITORY="${OPENSPP_POSTGIS_REPOSITORY:-postgis/postgis}"
    OPENSPP_POSTGIS_TAG="${OPENSPP_POSTGIS_TAG:-18-3.6-alpine}"
    OPENSPP_BUILD_IF_MISSING="${OPENSPP_BUILD_IF_MISSING:-false}"
    OPENSPP_SOURCE_REPO="${OPENSPP_SOURCE_REPO:-https://github.com/OpenSPP/OpenSPP2.git}"
    OPENSPP_SOURCE_REF="${OPENSPP_SOURCE_REF:-v19.0.2.0.0}"
    OPENSPP_SOURCE_DIR="${OPENSPP_SOURCE_DIR:-$RUN_DIR/repos/OpenSPP2}"

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
    # The image is not published yet, so it has to reach the cluster before the pods start.
    openspp_ensure_image
    log_with_verbose_check "$debug" "$INFO" "Using image ${OPENSPP_IMAGE_REPOSITORY}:${OPENSPP_IMAGE_TAG}"
    log_with_verbose_check "$debug" "$INFO" "Node architecture: ${OPENSPP_ARCH:-any} (db image ${OPENSPP_POSTGIS_REPOSITORY}:${OPENSPP_POSTGIS_TAG})"
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

    # Ingress host, formed like every other Gazelle service: <name>.${GAZELLE_DOMAIN}.
    local openspp_host="openspp.${GAZELLE_DOMAIN:-mifos.gazelle.test}"

    local helm_args=(
        upgrade --install "$OPENSPP_RELEASE_NAME" "$chart_dir"
        -n "$OPENSPP_NAMESPACE" --create-namespace
        --timeout "${startup_timeout:-900}s"
        --set "arch=${OPENSPP_ARCH}"
        --set "odoo.image.repository=${OPENSPP_IMAGE_REPOSITORY}"
        --set "odoo.image.tag=${OPENSPP_IMAGE_TAG}"
        --set "postgis.image.repository=${OPENSPP_POSTGIS_REPOSITORY}"
        --set "postgis.image.tag=${OPENSPP_POSTGIS_TAG}"
        --set "secrets.dbPassword=${db_pw}"
        --set "secrets.odooAdminPassword=${admin_pw}"
        --set "ingress.enabled=true"
        --set "ingress.host=${openspp_host}"
        --set "ingress.tls.secretName=openspp-tls"
        --set "odoo.env.PROXY_MODE=true"
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

# Smoke test, delegated to the one in tests/: pods Ready, the OpenSPP module installed and
# /web/health answering. It checks with kubectl exec, so it opens no local port.
openspp_verify() {
    local smoke="$RUN_DIR/tests/openspp/smoke.sh"
    if [[ ! -f "$smoke" ]]; then
        log_warn "Smoke test not found: $smoke"
        return 1
    fi

    local out
    if ! out=$(OPENSPP_NAMESPACE="$OPENSPP_NAMESPACE" bash "$smoke" 2>&1); then
        log_warn "Smoke test failed. Check the Odoo pod logs."
        echo "$out"
        return 1
    fi
    log_with_verbose_check "$debug" "$INFO" "$out"
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

    # Self-signed TLS cert for the ingress (mastercard.sh / paymenthub.sh pattern). The namespace
    # must exist before the Secret, so create it first (helm --create-namespace runs later).
    local openspp_host="openspp.${GAZELLE_DOMAIN:-mifos.gazelle.test}"
    kubectl create namespace "$OPENSPP_NAMESPACE" --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - > /dev/null 2>&1
    create_ingress_secret "$OPENSPP_NAMESPACE" "$openspp_host" "openspp-tls" \
        "${openspp_host},*.${GAZELLE_DOMAIN:-mifos.gazelle.test},localhost"

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
    echo "  OpenSPP:   https://${openspp_host}/web/login   (admin / admin)"
    echo "  Without that hostname:  kubectl port-forward svc/openspp-odoo 8069:8069 -n $OPENSPP_NAMESPACE"
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
