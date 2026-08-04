#!/usr/bin/env bash
# Build a container image with docker buildx and load it into the local k3s cluster.
# Author: Ismael Sallami
# Date: Jul 2026
#
# Two output paths:
#   default : build for the host architecture only, then import into k3s containerd.
#   --push  : build for one or more platforms and push to a registry.
#
# Why the default path is single-architecture: a multi-platform build produces a manifest
# list, which only a registry can store. It cannot be exported with 'docker save', so it
# cannot be imported into k3s. Ask for --push when you want a multi-platform image.
#
# The import step reuses src/utils/import-local-image-to-k3s.sh instead of duplicating it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPORT_SCRIPT="$SCRIPT_DIR/import-local-image-to-k3s.sh"

IMAGE_NAME=""
IMAGE_TAG=""
BUILD_CONTEXT="."
DOCKERFILE=""
BUILD_TARGET=""
PLATFORM=""
PUSH=false
IMPORT=true
VERBOSE=false
BUILD_ARGS=()
BUILDER_NAME="gazelle-multiarch"
BUILDER_OVERRIDE=""

showUsage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]
Build a container image with docker buildx and load it into the local k3s cluster.

Required:
    -n, --name         image name, e.g. ghcr.io/openmf/openspp
    -t, --tag          image tag, e.g. 19.0

Optional:
    -c, --context      build context directory (default: .)
    -f, --dockerfile   path to the Dockerfile (default: <context>/Dockerfile)
        --target       build stage to stop at, e.g. production
        --platform     platform list (default: linux/<host arch>)
        --push         push to the registry instead of importing into k3s
                       (required for a multi-platform build)
        --build-arg    build argument, repeatable, e.g. --build-arg FOO=bar
        --builder      buildx builder to use (default: the built-in "default" builder)
        --no-import    build only, do not import into k3s
    -v, --verbose      verbose output
    -h, --help         show this help

Examples:
    # OpenSPP, host architecture, imported into k3s
    $(basename "$0") -n ghcr.io/openmf/openspp -t 19.0 \\
        -c ../OpenSPP2 -f ../OpenSPP2/docker/Dockerfile --target production

    # multi-platform image pushed to a registry
    $(basename "$0") -n openmf/some-dpg -t 1.0.0 --platform linux/amd64,linux/arm64 --push
EOF
    exit 1
}

log() {
    if [[ "$VERBOSE" == true ]]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    fi
}

error() {
    echo "ERROR: $1" >&2
    exit 1
}

# Host architecture in Docker/Kubernetes naming.
# Same mapping as src/environmentSetup/k8s.sh.
detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)       echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) error "Unsupported architecture: $arch (only amd64 and arm64 are supported)" ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--name)       IMAGE_NAME="$2"; shift 2 ;;
        -t|--tag)        IMAGE_TAG="$2"; shift 2 ;;
        -c|--context)    BUILD_CONTEXT="$2"; shift 2 ;;
        -f|--dockerfile) DOCKERFILE="$2"; shift 2 ;;
        --target)        BUILD_TARGET="$2"; shift 2 ;;
        --platform)      PLATFORM="$2"; shift 2 ;;
        --push)          PUSH=true; shift ;;
        --build-arg)     BUILD_ARGS+=("--build-arg" "$2"); shift 2 ;;
        --builder)       BUILDER_OVERRIDE="$2"; shift 2 ;;
        --no-import)     IMPORT=false; shift ;;
        -v|--verbose)    VERBOSE=true; shift ;;
        -h|--help)       showUsage ;;
        *) error "Unknown option: $1 (use --help)" ;;
    esac
done

[[ -z "$IMAGE_NAME" ]] && error "Image name is required. Use -n or --name"
[[ -z "$IMAGE_TAG" ]] && error "Image tag is required. Use -t or --tag"

command -v docker &> /dev/null || error "docker not found. Install docker first."
docker buildx version &> /dev/null || error \
    "docker buildx not found. Install the buildx plugin (docker-buildx-plugin package, or see https://docs.docker.com/build/install-buildx/)."

# Default to the host architecture
HOST_ARCH="$(detect_arch)"
[[ -z "$PLATFORM" ]] && PLATFORM="linux/${HOST_ARCH}"

# A multi-platform build can only live in a registry, so refuse to build one locally
# instead of producing something that cannot be imported into k3s.
if [[ "$PLATFORM" == *,* && "$PUSH" != true ]]; then
    error "Multi-platform build requested ($PLATFORM) without --push.
A multi-platform build produces a manifest list, which only a registry can store: it cannot be
exported with 'docker save' and therefore cannot be imported into k3s.
Either add --push, or build a single platform (default: linux/${HOST_ARCH})."
fi

if [[ "$IMPORT" == true && "$PUSH" != true ]]; then
    [[ -x "$IMPORT_SCRIPT" ]] || error "Import script not found or not executable: $IMPORT_SCRIPT"
fi

[[ -d "$BUILD_CONTEXT" ]] || error "Build context not found: $BUILD_CONTEXT"
[[ -z "$DOCKERFILE" ]] && DOCKERFILE="$BUILD_CONTEXT/Dockerfile"
[[ -f "$DOCKERFILE" ]] || error "Dockerfile not found: $DOCKERFILE"

IMAGE_REF="${IMAGE_NAME}:${IMAGE_TAG}"

printf "\n******************************************\n"
printf " -- build and import image -- \n"
printf "***************  << START >>  *************\n\n"
printf "  image      : %s\n" "$IMAGE_REF"
printf "  platform   : %s (host arch: %s)\n" "$PLATFORM" "$HOST_ARCH"
printf "  context    : %s\n" "$BUILD_CONTEXT"
printf "  dockerfile : %s\n" "$DOCKERFILE"
[[ -n "$BUILD_TARGET" ]] && printf "  target     : %s\n" "$BUILD_TARGET"
printf "  output     : %s\n\n" "$([[ "$PUSH" == true ]] && echo "push to registry" || echo "local docker + k3s import")"

# Pick the builder explicitly instead of using whichever one the machine has selected.
#   single platform -> the built-in "default" builder (docker driver). It writes straight into
#                      the local docker image store, which is what 'docker save' reads, and it
#                      needs no extra container. Modern Docker runs BuildKit here, so cache
#                      mounts and TARGETARCH still work.
#   multi platform  -> our own builder with the docker-container driver, which is the only one
#                      that can build for a foreign architecture.
# --builder wins: on Docker Desktop the docker-driver builder is not always called "default",
# and that setup cannot be reproduced here, so leave an explicit way out instead of guessing.
BUILDER="${BUILDER_OVERRIDE:-default}"
if [[ "$PLATFORM" == *,* && -z "$BUILDER_OVERRIDE" ]]; then
    BUILDER="$BUILDER_NAME"
    if ! docker buildx inspect "$BUILDER_NAME" &> /dev/null; then
        log "creating buildx builder $BUILDER_NAME (docker-container driver)"
        docker buildx create --name "$BUILDER_NAME" --driver docker-container > /dev/null
    fi
    docker buildx inspect --builder "$BUILDER_NAME" --bootstrap > /dev/null
fi
log "using buildx builder $BUILDER"

buildx_args=(build --builder "$BUILDER" --platform "$PLATFORM" -t "$IMAGE_REF" -f "$DOCKERFILE")
[[ -n "$BUILD_TARGET" ]] && buildx_args+=(--target "$BUILD_TARGET")
[[ ${#BUILD_ARGS[@]} -gt 0 ]] && buildx_args+=("${BUILD_ARGS[@]}")
if [[ "$PUSH" == true ]]; then
    buildx_args+=(--push)
else
    # --load puts the result in the local docker image store, which is what 'docker save' reads.
    buildx_args+=(--load)
fi
buildx_args+=("$BUILD_CONTEXT")

printf "==> docker buildx %s\n\n" "${buildx_args[*]}"
docker buildx "${buildx_args[@]}" || error "buildx build failed for $IMAGE_REF"

if [[ "$PUSH" == true ]]; then
    printf "\n ** pushed %s (%s)\n" "$IMAGE_REF" "$PLATFORM"
    printf " Check it with: docker buildx imagetools inspect %s\n" "$IMAGE_REF"
    exit 0
fi

built_arch=$(docker image inspect "$IMAGE_REF" --format '{{.Architecture}}' 2>/dev/null || echo "unknown")
printf "\n ** built %s (architecture: %s)\n" "$IMAGE_REF" "$built_arch"

if [[ "$IMPORT" != true ]]; then
    printf " skipping the k3s import (--no-import)\n"
    exit 0
fi

# Reuse the existing import helper instead of duplicating 'docker save | k3s ctr images import'.
# Only pass -v when it was asked for: VERBOSE holds the string "true" or "false".
import_args=(-n "$IMAGE_NAME" -t "$IMAGE_TAG")
[[ "$VERBOSE" == true ]] && import_args+=(-v)

printf "\n==> importing into k3s using %s\n" "$(basename "$IMPORT_SCRIPT")"
if ! sudo "$IMPORT_SCRIPT" "${import_args[@]}"; then
    echo "ERROR: import into k3s failed. You can run it by hand with:" >&2
    echo "  docker save ${IMAGE_REF} | sudo k3s ctr images import -" >&2
    exit 1
fi

printf "\n ** done. Verify with: sudo k3s ctr images ls | grep %s\n" "$IMAGE_NAME"
