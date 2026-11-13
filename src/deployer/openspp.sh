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

# Architecture the pods must run on, in Kubernetes naming, used for the chart's nodeSelector.
# Read from the cluster, which is what the selector matches: an arm64 laptop can drive an amd64
# node. Empty when the nodes mix architectures, which deploys without a nodeSelector.
# Set OPENSPP_ARCH to override, or to "" for no nodeSelector.
openspp_detect_arch() {
    local arches
    arches=$(kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.architecture}' 2>/dev/null \
        | tr ' ' '\n' | sort -u)
    [[ -n "$arches" && $(wc -l <<< "$arches") -eq 1 ]] && echo "$arches"
    return 0
}

# Detect any "dedicated=<role>:NoSchedule" taints in the cluster (applied by e.g.
# `setup-env.sh -m join -r <role>` to reserve a node for one heavy component) and
# build a matching toleration list, so OpenSPP can still overflow onto that node
# when the default node runs out of capacity. Prints a JSON array (possibly "[]");
# a no-op on a single-node or otherwise-untainted cluster.
openspp_detect_dedicated_tolerations() {
    kubectl get nodes -o json 2>/dev/null | jq -c '
        [.items[].spec.taints[]? | select(.key == "dedicated" and .effect == "NoSchedule") | .value]
        | unique
        | map({key: "dedicated", operator: "Equal", value: ., effect: "NoSchedule"})
    ' 2>/dev/null
}

# Image name as the kubelet reports it: a name without a registry host resolves to Docker Hub,
# and a single-segment name lives under library/.
openspp_qualified_image() {
    local name="$1" host="${1%%/*}"
    if [[ "$name" != */* ]]; then
        echo "docker.io/library/$name"
    elif [[ "$host" == *.* || "$host" == *:* || "$host" == localhost ]]; then
        echo "$name"
    else
        echo "docker.io/$name"
    fi
}

# True when the image is already loaded in the cluster's container runtime. $1 = image:tag.
openspp_image_in_cluster() {
    kubectl get nodes -o jsonpath='{.items[*].status.images[*].names[*]}' 2>/dev/null \
        | tr ' ' '\n' | grep -qx "$(openspp_qualified_image "$1")"
}

# Asks the registry for the manifest only: 0 pullable, 1 not there, 2 nothing here to ask with.
# The node does the pulling, so a missing local docker is not an answer about the image. A pull
# limit is not an answer either, while a denied or unknown manifest is.
openspp_image_pullable() {
    local image="$1" out
    command -v docker &> /dev/null || return 2
    out=$(docker manifest inspect "$image" 2>&1) && return 0
    grep -qi 'toomanyrequests' <<< "$out" && return 2
    return 1
}

# Does the image publish a manifest for this architecture? 0 yes, 1 no, 2 cannot tell from here.
# $1 = image:tag, $2 = architecture.
openspp_image_has_arch() {
    local manifest
    command -v docker &> /dev/null || return 2
    manifest=$(docker manifest inspect --verbose "$1" 2>/dev/null) || return 2
    grep -q "\"architecture\": *\"$2\"" <<< "$manifest"
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

# Stop when an image the pods need has no build for this cluster, which no pull can fix. Only asks
# about images that are not on the node already, so a warm deploy still makes no network call.
# $1 = image:tag, $2 = what it is, $3 = how to change it.
openspp_require_arch() {
    local image="$1" role="$2" hint="$3" has=0
    [[ -n "$OPENSPP_ARCH" ]] || return 0
    openspp_image_in_cluster "$image" && return 0
    openspp_image_has_arch "$image" "$OPENSPP_ARCH" || has=$?
    [[ $has -eq 1 ]] || return 0

    log_error "The $role image $image publishes no ${OPENSPP_ARCH} manifest, so its pods cannot start on this cluster."
    log_error "$hint"
    exit 1
}

# Make sure the image is available to the cluster, building it when that is the only way left.
# The three checks go from cheapest to most expensive: reading the node is free, asking the
# registry is one short request, building is about half an hour. So the usual case, where the
# image is already there, makes no network call at all.
openspp_ensure_image() {
    local image="${OPENSPP_IMAGE_REPOSITORY}:${OPENSPP_IMAGE_TAG}"
    openspp_image_in_cluster "$image" && return 0

    local pullable=0
    openspp_image_pullable "$image" || pullable=$?
    if [[ $pullable -eq 0 ]]; then
        openspp_require_arch "$image" "application" \
            "Point OPENSPP_IMAGE_REPOSITORY and OPENSPP_IMAGE_TAG in config.ini [openspp] at a build for this architecture."
        log_with_level "$INFO" "Image $image is not loaded but can be pulled. Letting Kubernetes pull it."
        return 0
    fi
    if [[ $pullable -eq 2 ]]; then
        log_with_level "$INFO" "Image $image is not loaded and cannot be checked from here (no docker). Letting Kubernetes pull it; an unreachable image shows up as ImagePullBackOff while waiting for the pods."
        return 0
    fi

    # The build utility reports its own failure, and that is what is trusted here. The node's
    # image list is not: it is published by the kubelet and lags, so it still says no right
    # after an import.
    if [[ "$OPENSPP_BUILD_IF_MISSING" == "true" ]] && openspp_can_import_image \
        && openspp_build_image; then
        log_with_level "$INFO" "Image $image built and imported."
        return 0
    fi

    log_error "Image $image is not in the cluster and cannot be pulled."
    if [[ "$OPENSPP_BUILD_IF_MISSING" == "true" ]] && ! openspp_can_import_image; then
        log_error "It cannot be built here either: the import needs a k3s cluster running on this machine."
        log_error "Build it and push it to a registry:  src/utils/build-and-import-image.sh -n <registry>/openspp -t ${OPENSPP_IMAGE_TAG} -c <OpenSPP2 checkout> -f <OpenSPP2 checkout>/docker/Dockerfile --target production --push"
        log_error "Or build it on the cluster node itself and import it there."
    else
        log_error "Build and import it with:  src/utils/build-and-import-image.sh -n ${OPENSPP_IMAGE_REPOSITORY} -t ${OPENSPP_IMAGE_TAG} -c <OpenSPP2 checkout> -f <OpenSPP2 checkout>/docker/Dockerfile --target production"
        log_error "Or import an image you already built:  docker save $image | sudo k3s ctr images import -"
        if [[ "$OPENSPP_BUILD_IF_MISSING" != "true" ]]; then
            log_error "Set OPENSPP_BUILD_IF_MISSING = true in config.ini [openspp] to build it automatically."
        fi
    fi
    exit 1
}

# Exit when a required config value is empty or unset, rather than defaulting to a literal here.
# $@ = names of the required variables.
openspp_require_config() {
    local name
    for name in "$@"; do
        if [[ -z "${!name:-}" ]]; then
            log_error "$name is not set. Declare it in config/config.ini, section [openspp]."
            exit 1
        fi
    done
}

openspp_check_prerequisites() {
    OPENSPP_NAMESPACE="${OPENSPP_NAMESPACE:-openspp}"
    OPENSPP_RELEASE_NAME="${OPENSPP_RELEASE_NAME:-openspp}"
    # Deliberately false when unset: a missing key must not start a 30-minute build on its own.
    OPENSPP_BUILD_IF_MISSING="${OPENSPP_BUILD_IF_MISSING:-false}"
    OPENSPP_SOURCE_DIR="${OPENSPP_SOURCE_DIR:-$RUN_DIR/repos/OpenSPP2}"
    # Images, versions and the source pin live only in config.ini [openspp], so moving to a new
    # release is one file.
    openspp_require_config OPENSPP_IMAGE_REPOSITORY OPENSPP_IMAGE_TAG \
        OPENSPP_POSTGIS_REPOSITORY OPENSPP_POSTGIS_TAG \
        OPENSPP_SOURCE_REPO OPENSPP_SOURCE_REF

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
    # Needs the cluster, so it is resolved after the check above and not with the other defaults.
    OPENSPP_ARCH="${OPENSPP_ARCH-$(openspp_detect_arch)}"

    # The database image is checked first: it is the one upstream publishes for amd64 only, and
    # stopping here costs seconds instead of half an hour of building the application image.
    openspp_require_arch "${OPENSPP_POSTGIS_REPOSITORY}:${OPENSPP_POSTGIS_TAG}" "database" \
        "Set OPENSPP_POSTGIS_REPOSITORY in config.ini [openspp] to a multi-architecture build. For arm64:  OPENSPP_POSTGIS_REPOSITORY=imresamu/postgis ./run.sh -m deploy -a openspp   (see docs/BUILDING-IMAGES.md)"
    # Both images have to reach the cluster before the pods start.
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

    local dedicated_tolerations
    dedicated_tolerations=$(openspp_detect_dedicated_tolerations)

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

    if [[ -n "$dedicated_tolerations" && "$dedicated_tolerations" != "[]" ]]; then
        helm_args+=(--set-json "tolerations=${dedicated_tolerations}")
        log_with_verbose_check "$debug" "$INFO" "Tolerating dedicated-node taint(s) so OpenSPP can overflow there if needed: ${dedicated_tolerations}"
    fi

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

# Report what went wrong for a workload that never became Ready, naming the images the cluster
# could not pull instead of guessing which one it was. $1 = workload, for the message.
openspp_report_not_ready() {
    local failed
    failed=$(kubectl get pods -n "$OPENSPP_NAMESPACE" -o jsonpath='{range .items[*]}{range .status.initContainerStatuses[*]}{.image}{" "}{.state.waiting.reason}{"\n"}{end}{range .status.containerStatuses[*]}{.image}{" "}{.state.waiting.reason}{"\n"}{end}{end}' 2>/dev/null \
        | grep -E 'ImagePullBackOff|ErrImagePull' | awk '{print $1}' | sort -u)

    log_error "$1 did not become Ready in namespace $OPENSPP_NAMESPACE."
    if [[ -n "$failed" ]]; then
        log_error "The cluster could not pull: $(paste -sd' ' - <<< "$failed")"
        log_error "Check the name and the tag, or load the image into the node:  docker save <image> | sudo k3s ctr images import -"
    else
        log_error "Look at the pods and their logs:  kubectl get pods -n $OPENSPP_NAMESPACE"
    fi
}

openspp_wait_ready() {
    # PostGIS first, then Odoo. Odoo self-initialises on first boot (installs base + the module),
    # gated behind its startupProbe, so the wait uses the configured startup timeout: a shorter one
    # would report a failure while the pod still has probe budget left.
    if ! kubectl rollout status statefulset/openspp-postgis -n "$OPENSPP_NAMESPACE" --timeout=180s > /dev/null 2>&1; then
        openspp_report_not_ready "PostGIS"
        return 1
    fi
    if ! kubectl rollout status deployment/openspp-odoo -n "$OPENSPP_NAMESPACE" --timeout="${startup_timeout:-900}s" > /dev/null 2>&1; then
        openspp_report_not_ready "Odoo"
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

    # A redeploy drops the release and its volumes, so it goes after the checks above: a deploy that
    # cannot work should not have deleted the database first. Use -r false to upgrade in place.
    if [[ "${redeploy:-false}" == "true" ]]; then
        log_step "Removing the previous OpenSPP release (redeploy, the database is not kept)"
        cleanup_openspp
        log_ok
    fi

    # Self-signed TLS cert for the ingress (mastercard.sh / paymenthub.sh pattern). The namespace
    # must exist before the Secret, so create it first (helm --create-namespace runs later).
    local openspp_host="openspp.${GAZELLE_DOMAIN:-mifos.gazelle.test}"
    kubectl create namespace "$OPENSPP_NAMESPACE" --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - > /dev/null 2>&1
    create_ingress_secret "$OPENSPP_NAMESPACE" "$openspp_host" "openspp-tls" \
        "${openspp_host},*.${GAZELLE_DOMAIN:-mifos.gazelle.test},localhost"

    # Docker Hub credentials for this namespace, as the other components get them: the images are
    # pulled from there, and without credentials the node uses the anonymous rate limit. Does
    # nothing when config.ini [dockerhub] is empty.
    if [[ -x "$RUN_DIR/src/utils/k3s-docker-login.sh" ]]; then
        DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME:-}" DOCKERHUB_PASSWORD="${DOCKERHUB_PASSWORD:-}" \
            DOCKERHUB_EMAIL="${DOCKERHUB_EMAIL:-}" \
            "$RUN_DIR/src/utils/k3s-docker-login.sh" "$OPENSPP_NAMESPACE" > /dev/null 2>&1
    fi

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
