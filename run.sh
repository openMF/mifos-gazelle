#!/bin/bash
# run.sh -- Main entry point for Mifos Gazelle deployment scripts

# macOS ships bash 3.2 which lacks associative arrays (declare -A) and
# name references (local -n). Re-exec with Homebrew bash 5 when needed.
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    # Re-exec with an already-installed bash 4+
    for _brew_bash in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if [[ -x "$_brew_bash" ]]; then
            exec "$_brew_bash" "$0" "$@"
        fi
    done
    # Not found — locate brew and install bash as the non-root invoking user
    _brew_bin=""
    for _candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [[ -x "$_candidate" ]] && _brew_bin="$_candidate" && break
    done
    if [[ -z "$_brew_bin" ]]; then
        echo "ERROR: bash 4+ and Homebrew are both required on macOS." >&2
        echo "       Install Homebrew from https://brew.sh then re-run." >&2
        exit 1
    fi
    # Determine the non-root user to run brew as (brew refuses to run as root)
    _brew_user="${SUDO_USER:-}"
    if [[ -z "$_brew_user" || "$_brew_user" == "root" ]]; then
        _brew_user=$(stat -f '%Su' /dev/console 2>/dev/null || echo "")
    fi
    if [[ -z "$_brew_user" || "$_brew_user" == "root" ]]; then
        echo "ERROR: Cannot determine a non-root user to run 'brew install bash'." >&2
        echo "       Please run: brew install bash" >&2
        exit 1
    fi
    echo "INFO   bash 4+ not found. Installing via Homebrew (this may take a moment)..."
    if ! sudo -u "$_brew_user" "$_brew_bin" install bash; then
        echo "ERROR: 'brew install bash' failed. Please install it manually and re-run." >&2
        exit 1
    fi
    for _brew_bash in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if [[ -x "$_brew_bash" ]]; then
            exec "$_brew_bash" "$0" "$@"
        fi
    done
    echo "ERROR: bash 4+ still not found after install. Please check your Homebrew setup." >&2
    exit 1
fi

RUN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )" # the directory that this script is in
export RUN_DIR

# On macOS, sudo strips PATH so Homebrew binaries are not found.
# Prepend both known Homebrew locations so all subsequent commands work.
if [[ "$(uname -s)" == "Darwin" ]]; then
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
fi
########################################################################
# GLOBAL VARS
# these are not user configurables - for internal script use only
########################################################################
BASE_DIR=$( cd $(dirname "$0") ; pwd )
APPS_DIR="$BASE_DIR/repos"
CONFIG_DIR="$BASE_DIR/config"
UTILS_DIR="$BASE_DIR/src/utils"
DATA_LOADING_DIR="$UTILS_DIR/data-loading"
export UTILS_DIR DATA_LOADING_DIR

# Python interpreter: use the project-local venv when available so data-loading
# scripts have their dependencies (requests, etc.) without touching system Python.
# Falls back to system python3 if the venv hasn't been created yet (e.g. first run
# before env-setup, or when running a deploy directly against a remote cluster).
if [[ -x "$BASE_DIR/.venv/bin/python3" ]]; then
    PYTHON3="$BASE_DIR/.venv/bin/python3"
else
    PYTHON3="python3"
fi
export PYTHON3
INFRA_CHART_DIR="$BASE_DIR/src/deployer/helm/infra" 
NGINX_VALUES_FILE="$CONFIG_DIR/nginx_values.yaml"

# Mojaloop vNext 
VNEXT_LAYER_DIRS=("$APPS_DIR/vnext/packages/installer/manifests/crosscut" "$APPS_DIR/vnext/packages/installer/manifests/apps" "$APPS_DIR/vnext/packages/installer/manifests/reporting")

#PaymentHub EE 
PH_VALUES_FILE="$CONFIG_DIR/ph_values.yaml"

#MifosX 
MIFOSX_MANIFESTS_DIR="$APPS_DIR/mifosx/kubernetes/manifests"

# Source commandline.sh
source "$RUN_DIR/src/commandline/commandline.sh"

## Dependency versioning ##
KUBECTL_VERSION="v1.30.0"
HELM_VERSION="v3.14.4"


# Call main with all arguments
main "$@"