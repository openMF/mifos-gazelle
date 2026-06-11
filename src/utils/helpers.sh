#!/usr/bin/env bash
# helpers.sh -- Shared utility functions for Mifos Gazelle deployment

# Prevent direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This is a library file and should not be executed directly. Source it from another script."
    exit 1
fi

#------------------------------------------------------------------------------
# Function : sed_inplace
# Description: Cross-platform in-place sed. macOS (BSD) sed requires an explicit
#              backup extension after -i; GNU sed does not. Pass sed args exactly
#              as you would for GNU sed — the -i '' is added automatically on macOS.
# Usage: sed_inplace -e 's/foo/bar/' file
#------------------------------------------------------------------------------
sed_inplace() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

#------------------------------------------------------------------------------
# Function : check_sudo
# Description: Checks if the script is run with sudo from a non-root user.
#              Rejects direct root execution (e.g. 'sudo su -') because
#              SUDO_USER is cleared by su login shells, making it impossible
#              to determine the real invoking user and causing all artifacts
#              to be owned by root.
#------------------------------------------------------------------------------
check_sudo() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run with sudo: sudo ./setup-env.sh"
        exit 1
    fi
    if [[ -z "${SUDO_USER:-}" || "${SUDO_USER}" == "root" ]]; then
        log_error "Do not run as root directly (e.g. via 'sudo su -')."
        log_error "Run as your normal user with sudo: sudo ./setup-env.sh -e local -u \$USER"
        echo  "       Environment artifacts must be owned by you, not root."
        exit 1
    fi
}

#------------------------------------------------------------------------------
# Function : check_command_execution
# Description: Checks if a command executed successfully and logs an error if not.
# Parameters:
#   $1 - Exit code of the command
#   $2 - Command that was executed (for logging purposes)
#------------------------------------------------------------------------------
check_command_execution() {
    local exit_code=$1
    local cmd="$2"
    if [[ $exit_code -ne 0 ]]; then
        log_failed
        log_error "Command failed: $cmd"
        exit $exit_code
    fi
}

#------------------------------------------------------------------------------     
# Debug function to check if a function exists
#------------------------------------------------------------------------------
function_exists() {
    declare -f "$1" > /dev/null
    return $?
}

