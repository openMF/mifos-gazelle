#!/usr/bin/env bash
# setup-env.sh -- Privileged environment setup and teardown for Mifos Gazelle.
#
# Run with sudo once per machine to install k3s/Colima, OS packages,
# tools (/usr/local/bin), /etc/hosts entries, and the Python venv.
# Run with sudo -m cleanall to fully decommission the environment.
#
# Usage:
#   sudo ./setup-env.sh [-e local|mac|remote] [-u user] [-d true|false] [-f config]
#   sudo ./setup-env.sh -m cleanall [-e local|mac|remote] [-u user]

# macOS ships bash 3.2 which lacks associative arrays (declare -A) and
# name references (local -n). Re-exec with Homebrew bash 5 when needed.
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for brew_bash in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if [[ -x "$brew_bash" ]]; then
            exec "$brew_bash" "$0" "$@"
        fi
    done
    brew_bin=""
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [[ -x "$candidate" ]] && brew_bin="$candidate" && break
    done
    if [[ -z "$brew_bin" ]]; then
        echo "ERROR: bash 4+ and Homebrew are both required on macOS." >&2
        echo "       Install Homebrew from https://brew.sh then re-run." >&2
        exit 1
    fi
    brew_user="${SUDO_USER:-}"
    if [[ -z "$brew_user" || "$brew_user" == "root" ]]; then
        brew_user=$(stat -f '%Su' /dev/console 2>/dev/null || echo "")
    fi
    if [[ -z "$brew_user" || "$brew_user" == "root" ]]; then
        echo "ERROR: Cannot determine a non-root user to run 'brew install bash'." >&2
        echo "       Please run: brew install bash" >&2
        exit 1
    fi
    echo "INFO   bash 4+ not found. Installing via Homebrew (this may take a moment)..."
    if ! sudo -u "$brew_user" "$brew_bin" install bash; then
        echo "ERROR: 'brew install bash' failed. Please install it manually and re-run." >&2
        exit 1
    fi
    for brew_bash in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if [[ -x "$brew_bash" ]]; then
            exec "$brew_bash" "$0" "$@"
        fi
    done
    echo "ERROR: bash 4+ still not found after install. Please check your Homebrew setup." >&2
    exit 1
fi

RUN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export RUN_DIR

# On macOS, sudo strips PATH so Homebrew binaries are not found.
if [[ "$(uname -s)" == "Darwin" ]]; then
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
fi

########################################################################
# GLOBAL VARS (subset of run.sh — only what env setup needs)
########################################################################
BASE_DIR="$( cd "$(dirname "$0")" ; pwd )"
APPS_DIR="$BASE_DIR/repos"
CONFIG_DIR="$BASE_DIR/config"
UTILS_DIR="$BASE_DIR/src/utils"
DATA_LOADING_DIR="$UTILS_DIR/data-loading"
export UTILS_DIR DATA_LOADING_DIR

INFRA_CHART_DIR="$BASE_DIR/src/deployer/helm/infra"
NGINX_VALUES_FILE="$CONFIG_DIR/nginx_values.yaml"

# Source all modules (via commandline.sh which sources the rest)
source "$RUN_DIR/src/commandline/commandline.sh" || { echo "FATAL: Could not source commandline.sh"; exit 1; }

## Dependency versioning (must match run.sh) ##
KUBECTL_VERSION="v1.30.0"
HELM_VERSION="v3.14.4"

#------------------------------------------------------------------------------
# Function: show_setup_env_usage
#------------------------------------------------------------------------------
show_setup_env_usage() {
    echo "
    USAGE: sudo $0 [-e environment] [-u user] [-m mode] [-f config_file] [-d true|false]
           sudo $0 -m join -N node-host [-U ssh-user] [-i identity_file] [-r role]

    Privileged environment setup and teardown (run before ./run.sh).

    Example 1 : sudo $0                          # first-time setup — OS auto-detected (Linux/macOS)
    Example 2 : sudo $0 -u \$USER               # first-time setup with explicit user
    Example 3 : sudo $0 -e remote -u \$USER      # /etc/hosts only for a remote cluster
    Example 4 : sudo $0 -m cleanall              # full environment teardown
    Example 5 : sudo $0 -y                       # non-interactive (CI/pipeline — auto-accept changes)
    Example 6 : sudo $0 -m join -N 192.168.1.108 -U ubuntu -r openg2p
                                                  # join a 2nd node, dedicate it to the openg2p role

    Options:
    -m mode .............. setup (default) | cleanall | join
    -e environment ....... local (default) | remote
    -u user .............. non-root user for k8s operations (defaults to invoking user)
    -f config_file ....... path to config.ini (optional, defaults to config/config.ini)
    -d debug ............. true|false (optional, default=false)
    -y ................... auto-accept planned changes without prompting (for CI/pipelines)
    -h ................... display this message

    Options for -m join (run on the EXISTING k3s server, joins a NEW node to it):
    -N node-host .......... required — SSH-reachable IP/hostname of the node to join
    -U ssh-user ........... SSH user on that node (default: same as -u)
    -i identity_file ...... SSH private key for that node (default: ssh's own resolution)
    -r role ............... optional — taint+label the new node so ONLY workloads that
                             explicitly tolerate 'dedicated=<role>' schedule there. Useful
                             to isolate one heavy component (e.g. 'openg2p') on whichever
                             physical machine you choose — this is your call, not
                             auto-detected, since node hardware varies (e.g. a 16GB Pi 5
                             paired with an 8GB Pi 5, not two identical boards).
                             Omit -r to join it as a plain, untainted worker node.
    "
}

#------------------------------------------------------------------------------
# Function: main_setup_env
#------------------------------------------------------------------------------
main_setup_env() {
    # Early config detection for logging setup
    local early_config="$DEFAULT_CONFIG_FILE"
    local args=("$@")
    for ((i=0; i<${#args[@]}; i++)); do
        if [[ "${args[i]}" == "-f" && $((i+1)) -lt ${#args[@]} ]]; then
            early_config="${args[$((i+1))]}"
            break
        fi
    done
    setup_logging "$early_config"

    welcome

    # Must be run with sudo from a non-root user
    check_sudo

    install_crudini

    local -A cmd_args
    OPTIND=1
    while getopts "f:m:e:u:d:N:U:i:r:yhH" OPT; do
        case "$OPT" in
            f) cmd_args["config_file_path"]="${OPTARG}" ;;
            m) cmd_args["mode"]="${OPTARG}" ;;
            e) cmd_args["environment"]="${OPTARG}" ;;
            u) cmd_args["k8s_user"]="${OPTARG}" ;;
            d) cmd_args["debug"]="${OPTARG}" ;;
            N) join_node_host="${OPTARG}" ;;
            U) join_ssh_user="${OPTARG}" ;;
            i) join_identity_file="${OPTARG}" ;;
            r) join_role="${OPTARG}" ;;
            y) auto_yes="true" ;;
            h|H) show_setup_env_usage; exit 0 ;;
            *) show_setup_env_usage; exit 1 ;;
        esac
    done
    export auto_yes join_node_host join_ssh_user join_identity_file join_role

    if [[ -n "${cmd_args["config_file_path"]}" ]]; then
        CONFIG_FILE_PATH="${cmd_args["config_file_path"]}"
    fi
    log_with_level "$INFO" "Using config file: $CONFIG_FILE_PATH"

    load_config_from_file "$CONFIG_FILE_PATH"

    # config.ini's 'mode' is for run.sh (deploy/cleanapps) — ignore it here
    mode=""

    # CLI flags override
    if [[ -n "${cmd_args["mode"]}" ]];        then mode="${cmd_args["mode"]}"; fi
    if [[ -n "${cmd_args["k8s_user"]}" ]];    then k8s_user="${cmd_args["k8s_user"]}"; fi
    if [[ -n "${cmd_args["debug"]}" ]];       then debug="${cmd_args["debug"]}"; fi
    if [[ -n "${cmd_args["environment"]}" ]]; then environment="${cmd_args["environment"]}"; fi

    auto_detect_environment

    # Defaults
    mode="${mode:-setup}"
    debug="${debug:-false}"
    environment="${environment:-local}"

    # If k8s_user still unset (not in config, not via -u), derive from SUDO_USER
    if [[ -z "$k8s_user" ]]; then
        k8s_user="$(resolve_invoker_user)"
    fi

    # Validate
    if [[ "$mode" != "setup" && "$mode" != "cleanall" && "$mode" != "join" ]]; then
        log_error "Invalid mode '$mode'. setup-env.sh accepts: setup (default) | cleanall | join"
        show_setup_env_usage
        exit 1
    fi
    if [[ "$k8s_user" == "root" ]]; then
        log_error "The specified user cannot be root. Please specify a non-root user."
        exit 1
    fi
    if [[ "$environment" != "local" && "$environment" != "remote" && "$environment" != "mac" ]]; then
        log_error "Invalid environment '$environment'. Must be: local | remote"
        exit 1
    fi

    # Resolve user home and kubeconfig
    k8s_user_home=$(eval echo "~$k8s_user")
    if [[ -z "$kubeconfig_path" ]]; then
        kubeconfig_path="$k8s_user_home/.kube/config"
    fi
    export KUBECONFIG="$kubeconfig_path"

    if [[ "$mode" == "setup" ]]; then
        env_setup_main
    elif [[ "$mode" == "join" ]]; then
        env_join_node_main
    elif [[ "$mode" == "cleanall" ]]; then
        if [[ "$environment" != "remote" && "${auto_yes:-false}" != "true" ]]; then
            printf "\n*** WARNING: cleanall will remove the Kubernetes cluster (%s),\n" "$environment"
            printf "*** all deployed applications, /etc/hosts entries, and shell config.\n"
            printf "*** This cannot be undone. Continue? [y/N] "
            read -r _confirm </dev/tty
            if [[ "$_confirm" != "y" && "$_confirm" != "Y" ]]; then
                printf "Aborted.\n"
                exit 0
            fi
        fi
        env_cleanall_main
    fi
}

main_setup_env "$@"
