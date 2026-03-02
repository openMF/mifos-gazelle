#!/usr/bin/env bash

source "$RUN_DIR/src/utils/logger.sh" || { echo "FATAL: Could not source logger.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/utils/helpers.sh" || { echo "FATAL: Could not source helpers.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/environmentSetup/environmentSetup.sh" || { echo "FATAL: Could not source environmentSetup.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }
source "$RUN_DIR/src/deployer/deployer.sh" || { echo "FATAL: Could not source deployer.sh. Check RUN_DIR: $RUN_DIR"; exit 1; }

DEFAULT_CONFIG_FILE="$RUN_DIR/config/config.ini"

#------------------------------------------------------------------------------
# function: resolve_invoker_user
# Description: Resolves the username of the user who invoked the script,
#              handling cases where sudo is used.
#------------------------------------------------------------------------------
function resolve_invoker_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s\n' "$SUDO_USER"
    return
  fi
  if invoker="$(logname 2>/dev/null)"; then
    [[ -n "$invoker" ]] && printf '%s\n' "$invoker" && return
  fi
  if [[ -n "${LOGNAME:-}" && "${LOGNAME}" != "root" ]]; then
    printf '%s\n' "$LOGNAME"
    return
  fi
  whoami
}

#------------------------------------------------------------------------------
# Function : install_crudini
# Description: Installs the 'crudini' tool if it is not already installed.
#------------------------------------------------------------------------------
function install_crudini() {
    if ! command -v crudini &> /dev/null; then
        logWithLevel "$INFO" "crudini not found. Attempting to install..."
        if command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y crudini
        elif command -v dnf &> /dev/null; then
            sudo dnf install -y crudini
        elif command -v yum &> /dev/null; then
            sudo yum install -y crudini
        else
            logWithLevel "$ERROR" "Neither apt-get, dnf, nor yum found. Please install crudini manually."
            exit 1
        fi
        if ! command -v crudini &> /dev/null; then
            logWithLevel "$ERROR" "Failed to install crudini. Exiting."
            exit 1
        fi
        logWithLevel "$INFO" "crudini installed successfully."
    fi
}

#------------------------------------------------------------------------------
# Function : setup_logging
# Description: If logging=true in config.ini, tees all subsequent stdout+stderr
#              to /tmp/gazelle-YYYYMMDD-HHMM.log. Uses grep rather than crudini
#              because crudini may not be installed yet when this is called.
#              Must be called before welcome() to capture the full run.
# Parameters:
#   $1 - Path to config.ini
#------------------------------------------------------------------------------
function setup_logging() {
    local config="$1"
    local log_enabled
    log_enabled=$(grep -E '^\s*logging\s*=' "$config" 2>/dev/null | tail -1 \
        | awk -F'=' '{print $2}' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    if [[ "$log_enabled" == "true" ]]; then
        GAZELLE_LOG="/tmp/gazelle-$(date +%Y%m%d-%H%M).log"
        export GAZELLE_LOG
        exec > >(tee -a "$GAZELLE_LOG") 2>&1
        echo "  Log: $GAZELLE_LOG"
        echo
    fi
}

#------------------------------------------------------------------------------
# Function : loadConfigFromFile
# Description: Loads configuration parameters from the specified INI file using 'crudini'.
# Parameters:
#   $1 - Path to the configuration INI file.
#------------------------------------------------------------------------------
function loadConfigFromFile() {
    local config_path="$1"
    logWithLevel "$INFO" "Attempting to load configuration from $config_path using crudini."

    if [ ! -f "$config_path" ]; then
        logWithLevel "$WARNING" "Configuration file not found: $config_path. Proceeding with defaults and command-line arguments."
        return 0
    fi

    # Read [general] section
    local config_mode=$(crudini --get "$config_path" general mode 2>/dev/null)
    if [[ -n "$config_mode" ]]; then mode="$config_mode"; fi
    local config_gazelle_domain=$(crudini --get "$config_path" general GAZELLE_DOMAIN 2>/dev/null)
    if [[ -n "$config_gazelle_domain" ]]; then GAZELLE_DOMAIN="$config_gazelle_domain"; fi
    local config_gazelle_version=$(crudini --get "$config_path" general GAZELLE_VERSION 2>/dev/null)
    if [[ -n "$config_gazelle_version" ]]; then GAZELLE_VERSION="$config_gazelle_version"; fi

    # Read [kubernetes] section
    local config_environment=$(crudini --get "$config_path" kubernetes environment 2>/dev/null)
    if [[ -n "$config_environment" ]]; then environment="$config_environment"; fi
    local config_k8s_version=$(crudini --get "$config_path" kubernetes k8s_version 2>/dev/null)
    if [[ -n "$config_k8s_version" ]]; then k8s_version="$config_k8s_version"; fi
    local config_k8s_user=$(crudini --get "$config_path" kubernetes k8s_user 2>/dev/null)
    if [[ -n "$config_k8s_user" ]]; then
        if [[ "$config_k8s_user" == "\$USER" || "$config_k8s_user" == '$USER' ]]; then
            k8s_user="$(resolve_invoker_user)"
            #logWithLevel "$INFO" "Expanded '\$USER' in config to invoking username: $k8s_user"
        else
            k8s_user="$config_k8s_user"
        fi
    fi
    local config_kubeconfig_path=$(crudini --get "$config_path" kubernetes kubeconfig_path 2>/dev/null)
    if [[ -n "$config_kubeconfig_path" ]]; then
        if [[ "$config_kubeconfig_path" == "~/.kube/config" ]]; then
            k8s_user_home=$(eval echo "~$k8s_user")
            kubeconfig_path="$k8s_user_home/.kube/config"
            #logWithLevel "$INFO" "Expanded kubeconfig_path to: $kubeconfig_path"
        else
            kubeconfig_path="$config_kubeconfig_path"
        fi
    fi
    local config_helm_version=$(crudini --get "$config_path" kubernetes helm_version 2>/dev/null)
    if [[ -n "$config_helm_version" ]]; then helm_version="$config_helm_version"; fi
    # local config_k8s_current_release_list=$(crudini --get "$config_path" kubernetes k8s_current_release_list 2>/dev/null)
    # if [[ -n "$config_k8s_current_release_list" ]]; then k8s_current_release_list="$config_k8s_current_release_list"; fi
    local config_min_ram=$(crudini --get "$config_path" kubernetes min_ram 2>/dev/null)
    if [[ -n "$config_min_ram" ]]; then min_ram="$config_min_ram"; fi
    local config_min_free_space=$(crudini --get "$config_path" kubernetes min_free_space 2>/dev/null)
    if [[ -n "$config_min_free_space" ]]; then min_free_space="$config_min_free_space"; fi
    local config_linux_os_list=$(crudini --get "$config_path" kubernetes linux_os_list 2>/dev/null)
    if [[ -n "$config_linux_os_list" ]]; then linux_os_list="$config_linux_os_list"; fi
    local config_ubuntu_ok_versions_list=$(crudini --get "$config_path" kubernetes ubuntu_ok_versions_list 2>/dev/null)
    if [[ -n "$config_ubuntu_ok_versions_list" ]]; then ubuntu_ok_versions_list="$config_ubuntu_ok_versions_list"; fi

    # Read app enablement flags and construct the 'apps' variable
    local enabled_apps_list=""
    local valid_apps=("infra" "vnext" "phee" "mifosx" "mastercard-demo")

    for app_name in "${valid_apps[@]}"; do
        local app_enabled=$(crudini --get "$config_path" "$app_name" enabled 2>/dev/null)
        app_enabled=$(echo "$app_enabled" | tr '[:upper:]' '[:lower:]')
        if [[ "$app_enabled" == "true" ]]; then
            enabled_apps_list+=" $app_name"
            #logWithLevel "$INFO" "Config indicates '$app_name' is enabled."
        fi
    done
    apps=$(echo "$enabled_apps_list" | xargs)

    # Dynamically load all variables from config.ini sections
    # Get all sections from config file
    local all_sections=$(crudini --get "$config_path" 2>/dev/null)

    for section in $all_sections; do
        # Get all keys in this section
        local section_keys=$(crudini --get "$config_path" "$section" 2>/dev/null || true)

        # Export each key-value pair
        while IFS= read -r var_name; do
            if [[ -n "$var_name" ]]; then
                # Check if variable is already set to a non-empty value (preserves special handling like k8s_user)
                current_value="${!var_name:-}"
                if [[ -z "$current_value" ]]; then
                    value=$(crudini --get "$config_path" "$section" "$var_name" 2>/dev/null)
                    if [[ -n "$value" ]]; then
                        # Store value as-is, let bash expand variables when referenced
                        eval "export $var_name=\"\$value\""
                        #logWithLevel "$INFO" "Loaded from config [$section]: $var_name=$value"
                    fi
                #else
                    #logWithLevel "$INFO" "Skipped (already set) [$section]: $var_name=$current_value"
                fi
            fi
        done <<< "$section_keys"
    done
}

#------------------------------------------------------------------------------
# Function : welcome
# Description: Displays a welcome message for Mifos Gazelle.
#------------------------------------------------------------------------------
function welcome {
    echo -e "${BLUE}"
    echo -e " ██████   █████  ███████ ███████ ██      ██      ███████ "
    echo -e "██       ██   ██    ███  ██      ██      ██      ██      "
    echo -e "██   ███ ███████   ███   █████   ██      ██      █████   "
    echo -e "██    ██ ██   ██  ███    ██      ██      ██      ██      "
    echo -e " ██████  ██   ██ ███████ ███████ ███████ ███████ ███████ "
    echo -e "${RESET}"
    echo -e "Mifos Gazelle — Digital Public Infrastructure as a Solution (DaaS) deployment tool."
    echo -e "Deploys MifosX, Payment Hub EE and Mojaloop vNext on Kubernetes."
    echo
}

#------------------------------------------------------------------------------
# Function : showUsage
# Description: Displays usage information for the script.
#------------------------------------------------------------------------------
function showUsage {
    echo "
    USAGE: $0 [-f <config_file_path>] -m [mode] -u [user] -a [apps] -e [environment] -d [true/false] -r [true/false]
    Example 1 : sudo $0                                          # deploy all apps enabled in config.ini and user \$USER from config.ini
    Example 2 : sudo $0 -m cleanapps  -d true                    # delete all apps enabled in config.init, leave environment with debug mode \$USER from config.ini
    Example 3 : sudo $0 -m cleanall                              # delete all apps, all local Kubernetes artifacts, and local kubernetes server
    Example 4 : sudo $0 -a phee                                  # deploy PHEE only, user \$USER from config.ini
    Example 6 : sudo $0 -a \"mifosx,vnext\"                        # deploy MifosX and vNext only 
    Example 7 : sudo $0 -f /opt/my_config.ini                    # Use a custom config file
    Example 8 : sudo $0 -a \"phee,mifosx\" -e remote -d true       # deploy PHEE and MifosX on remote cluster with debug mode

    Options:
    -f config_file_path .. Specify an alternative config.ini file path (optional)
    -m mode .............. deploy|cleanapps|cleanall (required)
    -u user .............. (non root) user that the process will use for execution (required)
    -a apps .............. Comma-separated list of apps (vnext,phee,mifosx,infra,mastercard-demo) or 'all' (optional)
    -e environment ....... Cluster environment (local or remote, optional, default=local)
    -d debug ............. Enable debug mode (true|false, optional, default=false)
    -r redeploy .......... Force redeployment of apps (true|false, optional, default=true)
    -h|H ................. Display this message
    "
}

#------------------------------------------------------------------------------
# Function : check_duplicates
# Description: Checks for duplicate entries in an array.
# Parameters:
#   $1 - Name of the array variable to check (passed by name).
#------------------------------------------------------------------------------
function check_duplicates() {
    local -n arr=$1
    declare -A seen
    
    for app in "${arr[@]}"; do
        if [[ ${seen[$app]} ]]; then
            #echo "Error: Duplicate entry found: '$app'"
            return 1
        fi
        seen[$app]=1
    done
    return 0
}

#------------------------------------------------------------------------------
# Function : validateInputs
# Description: Validates command-line inputs and configuration parameters.
#------------------------------------------------------------------------------
function validateInputs {
    if [[ -z "$mode" || -z "$k8s_user" ]]; then
        log_error "Required options -m (mode) and -u (user) must be provided."
        showUsage
        exit 1
    fi

    if [[ "$k8s_user" == "root" ]]; then
        log_error "The specified user cannot be root. Please specify a non-root user."
        showUsage
        exit 1
    fi

    if [[ "$mode" != "deploy" && "$mode" != "cleanapps" && "$mode" != "cleanall" ]]; then
        log_error "Invalid mode '$mode'. Must be one of: deploy, cleanapps, cleanall."
        showUsage
        exit 1
    fi

    if [[ "$mode" == "deploy" || "$mode" == "cleanapps" ]]; then
        if [[ -z "$apps" ]]; then
            log_warn "No apps specified via -a or config file. Defaulting to 'all'."
            apps="all"
        fi
        local ALL_VALID_APPS="infra vnext phee mifosx mastercard-demo all"
        local CORE_APPS="infra vnext phee mifosx"

        local current_apps_array
        IFS=' ' read -r -a current_apps_array <<< "$apps"
        logWithVerboseCheck "$debug" "$DEBUG" "Apps array: ${current_apps_array[*]}"

        local found_all_keyword="false"
        local specific_apps_count=0

        for app_item in "${current_apps_array[@]}"; do
            if ! [[ " $ALL_VALID_APPS " =~ " $app_item " ]]; then
                log_error "Invalid app '$app_item'. Must be one of: ${ALL_VALID_APPS// /, }."
                showUsage
                exit 1
            fi
            if [[ "$app_item" == "all" ]]; then
                found_all_keyword="true"
            else
                ((specific_apps_count++))
            fi
        done

        # Check for duplicate apps
        if ! check_duplicates current_apps_array; then
            log_error "Duplicate applications specified in -a flag."
            showUsage
            exit 1
        fi

        if [[ "$found_all_keyword" == "true" ]]; then
            if [[ "$specific_apps_count" -gt 0 ]]; then
                log_error "Cannot combine 'all' with specific apps. Use either 'all' or a list, not both."
                showUsage
                exit 1
            fi
            apps="$CORE_APPS"
            logWithVerboseCheck "$debug" "$DEBUG" "Expanded 'all' to: $apps"
        fi

        logWithVerboseCheck "$debug" "$DEBUG" "Apps to process: $apps"
        if [[ " $apps " =~ " infra " ]]; then
            if [[ "$mode" == "deploy" ]]; then
                # for mode = deploy ensure 'infra' is first app if present
                apps="infra $(echo $apps | sed 's/infra//')"
                apps=$(echo $apps | xargs)
            else # mode = cleanapps
                # for mode = cleanapps ensure 'infra' is last app if present
                apps="$(echo $apps | sed 's/infra//') infra"
                apps=$(echo $apps | xargs)
            fi
        fi
        logWithVerboseCheck "$debug" "$DEBUG" "Final app order: $apps"
    fi

    if [[ -n "$debug" && "$debug" != "true" && "$debug" != "false" ]]; then
        log_error "Invalid value for debug. Use 'true' or 'false'."
        showUsage
        exit 1
    fi

    if [[ -n "$redeploy" && "$redeploy" != "true" && "$redeploy" != "false" ]]; then
        log_error "Invalid value for redeploy. Use 'true' or 'false'."
        showUsage
        exit 1
    fi

    if [[ -n "$environment" && "$environment" != "local" && "$environment" != "remote" ]]; then
        log_error "Invalid environment '$environment'. Must be 'local' or 'remote'."
        showUsage
        exit 1
    fi

    if [[ "$environment" == "local" ]]; then
        if [[ -z "$k8s_version" ]]; then
            log_error "k8s_version must be specified for local environment."
            showUsage
            exit 1
        fi
    fi

    if [[ "$environment" == "remote" && -n "$kubeconfig_path" ]]; then
        if [[ ! -f "$kubeconfig_path" ]]; then
            log_error "kubeconfig_path '$kubeconfig_path' does not exist or is not a file."
            showUsage
            exit 1
        fi
    fi

    if [[ ! " $linux_os_list " =~ " Ubuntu " ]]; then
        log_error "Only Ubuntu is supported in linux_os_list: $linux_os_list."
        showUsage
        exit 1
    fi

    local os_version=$(lsb_release -r -s | cut -d'.' -f1)
    if [[ ! " $ubuntu_ok_versions_list " =~ " $os_version " ]]; then
        log_error "Ubuntu version '$os_version' is not supported. Supported versions: $ubuntu_ok_versions_list."
        showUsage
        exit 1
    fi

    environment="${environment:-local}"
    debug="${debug:-false}"
    redeploy="${redeploy:-true}"
    if [[ "$environment" == "remote" && -z "$kubeconfig_path" ]]; then
        k8s_user_home=$(eval echo "~$k8s_user")
        kubeconfig_path="$k8s_user_home/.kube/config"
        logWithLevel "$INFO" "No kubeconfig_path specified in config.ini for remote environment. Defaulting to $kubeconfig_path"
    fi
} #validateInputs

#------------------------------------------------------------------------------
# Function : getOptions
# Description: Parses command-line options and populates a map with the values.
# Parameters:
#   $1 - Name of the associative array to populate with options.
#   Remaining parameters - Command-line arguments to parse.
#------------------------------------------------------------------------------
function getOptions() {
    local -n options_map=$1
    shift

    OPTIND=1
    while getopts "m:k:d:a:v:u:r:f:e:hH" OPTION ; do
        case "${OPTION}" in
            f) options_map["config_file_path"]="${OPTARG}" ;;
            m) options_map["mode"]="${OPTARG}" ;;
            d) options_map["debug"]="${OPTARG}" ;;
            a) options_map["apps"]="${OPTARG}" ;;
            u) options_map["k8s_user"]="${OPTARG}" ;;
            r) options_map["redeploy"]="${OPTARG}" ;;
            e) options_map["environment"]="${OPTARG}" ;;
            h|H) showUsage;
                 exit 0 ;;
            *) echo "Unknown option: -${OPTION}"
               showUsage;
               exit 1 ;;
        esac
    done
}

#------------------------------------------------------------------------------
# Function : cleanUp
# Description: Performs graceful cleanup on script exit.
#------------------------------------------------------------------------------
function cleanUp() {
    echo
    log_warn "Caught interrupt — performing graceful cleanup."
    exit 2
}

#------------------------------------------------------------------------------
# Function : trapCtrlc
# Description: Handles Ctrl-C (SIGINT) signal to perform cleanup.
#------------------------------------------------------------------------------
function trapCtrlc {
    echo
    cleanUp
}

trap "trapCtrlc" 2


# Global variables that will hold the final configuration
mode=""
#k8s_user=""
apps=""
environment=""
debug="false"
redeploy="true"
kubeconfig_path=""
#helm_version=""
# min_ram=6
# min_free_space=30
# linux_os_list="Ubuntu"
#ubuntu_ok_versions_list=""
export KUBECONFIG=$kubeconfig_path
CONFIG_FILE_PATH="$DEFAULT_CONFIG_FILE"

function main {
    # Determine config file path early (before full option parsing) so that
    # logging can be set up before welcome() prints anything.
    local _early_config="$DEFAULT_CONFIG_FILE"
    local _args=("$@")
    for ((i=0; i<${#_args[@]}; i++)); do
        if [[ "${_args[i]}" == "-f" && $((i+1)) -lt ${#_args[@]} ]]; then
            _early_config="${_args[$((i+1))]}"
            break
        fi
    done
    setup_logging "$_early_config"

    welcome
    install_crudini

    declare -A cmd_args_map
    getOptions cmd_args_map "$@"

    if [[ -n "${cmd_args_map["config_file_path"]}" ]]; then
        CONFIG_FILE_PATH="${cmd_args_map["config_file_path"]}"
    fi
    logWithLevel "$INFO" "Using config file: $CONFIG_FILE_PATH"

    loadConfigFromFile "$CONFIG_FILE_PATH"


    if [[ -n "${cmd_args_map["mode"]}" ]]; then mode="${cmd_args_map["mode"]}"; fi
    if [[ -n "${cmd_args_map["k8s_user"]}" ]]; then k8s_user="${cmd_args_map["k8s_user"]}"; fi
    if [[ -n "${cmd_args_map["apps"]}" ]]; then
        apps=$(echo "${cmd_args_map["apps"]}" | tr ',' ' ')
        logWithLevel "$INFO" "CLI apps converted to space-separated: $apps"
    fi
    if [[ -n "${cmd_args_map["debug"]}" ]]; then debug="${cmd_args_map["debug"]}"; fi
    if [[ -n "${cmd_args_map["redeploy"]}" ]]; then redeploy="${cmd_args_map["redeploy"]}"; fi
    if [[ -n "${cmd_args_map["environment"]}" ]]; then environment="${cmd_args_map["environment"]}"; fi

    validateInputs

    if [ "$mode" == "deploy" ]; then
        echo -e "${YELLOW}WARN${RESET}   This deployment is recommended for demo, test and educational purposes only."
        echo
        env_setup_main "$mode"
        deployApps "$apps" "$redeploy"
    elif [ "$mode" == "cleanapps" ]; then
        logWithVerboseCheck "$debug" "$INFO" "Cleaning up Mifos Gazelle applications only"
        env_setup_main "$mode"
        deleteApps "$apps"
    elif [ "$mode" == "cleanall" ]; then
        env_setup_main "$mode"
        # env_setup_main will not remove remote cluster so need to run deleteApps
        if [[ "$environment" == "remote" ]]; then
            deleteApps "$mifosx_instances" "all"
        fi
    else
        showUsage
        exit 1
    fi
}