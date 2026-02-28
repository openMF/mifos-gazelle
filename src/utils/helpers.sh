#!/usr/bin/env bash
# helpers.sh -- Shared utility functions for Mifos Gazelle deployment

# Logging (keep standalone compatibility)
source "$(dirname "${BASH_SOURCE[0]}")/logger.sh"

# Prevent direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    logWithLevel "$ERROR" "This is a library file and should not be executed directly. Source it from another script."
    exit 1
fi

#------------------------------------------------------------------------------
# Function : check_sudo
# Description: Checks if the script is run with sudo or as root user.
#------------------------------------------------------------------------------
function check_sudo() {
    if [[ $EUID -ne 0 ]]; then
        logWithLevel "$ERROR" "This script must be run with sudo or as root user"
        exit 1
    fi
}

#------------------------------------------------------------------------------
# Function : run_as_user
# Description: Runs a command as the specified Kubernetes user with the correct KUBECONFIG.
# Parameters:
#   $1 - Command to run
#------------------------------------------------------------------------------
function run_as_user() {
    local command="$1"
    # Debug: Log the command being executed
    #logWithVerboseCheck "$debug" debug "Running as $k8s_user: $command"
    
    # Execute the command as k8s_user and capture output and exit code
    local output
    output=$(su - "$k8s_user" -c "export KUBECONFIG=$kubeconfig_path; $command" 2>/dev/null)
    local exit_code=$?
    
    # Output the command result for the caller to capture
    echo "$output"
    
    # Return the actual exit code
    return $exit_code
}

#------------------------------------------------------------------------------
# Function : check_command_execution
# Description: Checks if a command executed successfully and logs an error if not.
# Parameters:
#   $1 - Exit code of the command
#   $2 - Command that was executed (for logging purposes)
#------------------------------------------------------------------------------
function check_command_execution() {
    local exit_code=$1
    local cmd="$2"
    if [[ $exit_code -ne 0 ]]; then
        logWithLevel "$ERROR" "Command execution failed: $cmd"
        logWithVerboseCheck "$debug" error "Failed to execute: $cmd"
        exit $exit_code
    fi
}

#------------------------------------------------------------------------------     
# Debug function to check if a function exists
#------------------------------------------------------------------------------
function function_exists() {
    declare -f "$1" > /dev/null
    return $?
}

