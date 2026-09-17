#!/usr/bin/env bash
# publish local image to k3s kubernetes
# Author: Tom Daly
# Date: Oct 2024
# Mainly useful for dev/test of Mifos Gazelle components

set -euo pipefail

# Default values
IMAGE_NAME=""
IMAGE_TAG=""
VERBOSE=false

showUsage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]
Publish a local Docker image to the k3s cluster's containerd runtime.
On Linux this loads directly into the local k3s; on macOS with Colima running,
the image is streamed into the k3s containerd inside the Colima VM instead.

Required Options:
    -n, --name         Docker image name
    -t, --tag          Docker image tag

Optional Options:
    -v, --verbose      Enable verbose output
    -h, --help         Show this help message

Example:
    $(basename "$0") -n myapp -t latest
    $(basename "$0") --name myapp --tag v1.0.0

Note: On Linux this script must be run as root (e.g. via sudo). On macOS/Colima
it must NOT be run with sudo -- 'docker' needs to run as the invoking user to
reach the Colima VM's daemon, and 'colima ssh' escalates to root inside the VM
for the import step on its own.
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

is_colima_running() {
    command -v colima &> /dev/null && colima status 2>/dev/null | grep -q "running"
}

set_user() {
    # set the k8s_user
    # $SUDO_USER is set when the script is run with sudo, which is how it is normally invoked.
    # Fall back to the session record for a plain root shell; 'who am i' is empty without a tty,
    # so on its own it fails over a non-interactive ssh or in CI.
    k8s_user="${SUDO_USER:-$(who am i | cut -d " " -f1)}"
    [[ -z "$k8s_user" ]] && error "Cannot determine the user that owns the docker images. Run this with sudo."
    log "k8s_user = $k8s_user"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--name)
            IMAGE_NAME="$2"
            shift 2
            ;;
        -t|--tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            showUsage
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# Validate required parameters
[[ -z "$IMAGE_NAME" ]] && error "Image name is required. Use -n or --name"
[[ -z "$IMAGE_TAG" ]] && error "Image tag is required. Use -t or --tag"

IMAGE_REF="${IMAGE_NAME}:${IMAGE_TAG}"

# Print header
printf "\n\n******************************************\n"
printf " -- publish local image to k3s -- \n"
printf "*************** << START >> *******************\n\n"

if is_colima_running; then
    # The k3s cluster lives inside the Colima VM; there is no k3s binary or containerd on
    # the macOS host to import into. 'docker' on the host already talks to the VM's daemon
    # (via the colima context) as the normal user, so none of the su/root juggling below is
    # needed here -- only the import step needs root, and 'colima ssh' escalates to that
    # inside the VM by itself.
    [[ "$EUID" -eq 0 ]] && error "Do not run this with sudo on macOS/Colima: docker needs to run as your normal user to reach the Colima VM's daemon."

    printf "==> streaming docker image %s into the Colima VM's k3s containerd\n" "$IMAGE_REF"
    if ! docker save "$IMAGE_REF" | colima ssh -- sudo k3s ctr images import -; then
        error "Failed to import image into k3s inside the Colima VM"
    fi

    printf "\n ** image appears to have imported ok\n"
    printf " You can check it exists by running.. \n"
    printf " colima ssh -- sudo k3s ctr images list | grep %s \n" "$IMAGE_NAME"
    exit 0
fi

# Linux / native k3s path
[[ "$EUID" -ne 0 ]] && error "Please run as root"

# Set user
set_user

# Define tarfile path
# A registry-qualified image name contains slashes (ghcr.io/openmf/openspp), and those cannot go
# straight into a file path: docker save would fail with "invalid output path". Flatten them.
# The tag is part of the name so two tags of the same image do not share the file.
tarfile="/tmp/$(echo "$IMAGE_REF" | tr '/:' '__').tar"

# Clean up any existing tarfile
if [[ -f "$tarfile" ]]; then
    log "Removing existing tarfile: $tarfile"
    rm -f "$tarfile"
fi

# Export Docker image
printf "==> export docker image using docker save --output %s %s \n" "$tarfile" "$IMAGE_REF"
if ! su - "$k8s_user" -c "docker save --output $tarfile $IMAGE_REF"; then
    error "Failed to save Docker image"
fi

# Import image to k3s
printf "==> import image using: k3s ctr images import %s \n" "$tarfile"
if ! k3s ctr images import "$tarfile"; then
    error "Failed to import image to k3s"
fi

# Cleanup
printf "==> cleaning up, removing tarfile etc\n"
rm -f "$tarfile"

# Success message
printf "\n ** images appear to have imported ok\n"
printf " You can check they exist by running.. \n"
printf " sudo k3s ctr images list | grep %s \n" "$IMAGE_NAME"
