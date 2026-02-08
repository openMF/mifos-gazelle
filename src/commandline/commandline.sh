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
    local valid_apps=("infra" "vnext" "phee" "mifosx")

    for app_name in "${valid_apps[@]}"; do
        local app_enabled=$(crudini --get "$config_path" "$app_name" enabled 2>/dev/null)
        app_enabled=$(echo "$app_enabled" | tr '[:upper:]' '[:lower:]')
        if [[ "$app_enabled" == "true" ]]; then
            enabled_apps_list+=" $app_name"
            #logWithLevel "$INFO" "Config indicates '$app_name' is enabled."
        fi
    done
    apps=$(echo "$enabled_apps_list" | xargs)

    # Override supported global variables from config.ini
    declare -A override_map=(
        [general]="GAZELLE_DOMAIN GAZELLE_VERSION"
        [mysql]="MYSQL_SERVICE_NAME MYSQL_SERVICE_PORT LOCAL_PORT MAX_WAIT_SECONDS MYSQL_HOST"
        [infra]="INFRA_NAMESPACE INFRA_RELEASE_NAME"
        [vnext]="VNEXTBRANCH VNEXTREPO_DIR VNEXT_NAMESPACE VNEXT_REPO_LINK"
        [phee]="PHBRANCH PHREPO_DIR PH_NAMESPACE PH_RELEASE_NAME PH_REPO_LINK PH_EE_ENV_TEMPLATE_REPO_LINK PH_EE_ENV_TEMPLATE_REPO_BRANCH PH_EE_ENV_TEMPLATE_REPO_DIR"
        [mifosx]="MIFOSX_NAMESPACE MIFOSX_REPO_DIR MIFOSX_BRANCH MIFOSX_REPO_LINK"
        [kubernetes]="helm_version k8s_version min_ram min_free_space linux_os_list ubuntu_ok_versions_list"
    )

    for section in "${!override_map[@]}"; do
        for var_name in ${override_map[$section]}; do
            value=$(crudini --get "$config_path" "$section" "$var_name" 2>/dev/null)
            if [[ -n "$value" ]]; then
                eval "$var_name=\"\$value\""
                export "$var_name"
                #logWithLevel "$INFO" "Overridden from config [$section]: $var_name=$value"
            fi
        done
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
    echo -e "Mifos Gazelle - a Mifos Digital Public Infrastructure as a Solution (DaaS) deployment tool."
    echo -e "                deploying Core DPGs MifosX, PaymentHub EE and vNext on Kubernetes."
    # echo -e "Version: $GAZELLE_VERSION"
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
    Example 9 : sudo $0 -m deploy -p aks                       # deploy to Azure AKS (implies remote)

    Options:
    -f config_file_path .. Specify an alternative config.ini file path (optional)
    -m mode .............. deploy|cleanapps|cleanall (required)
    -u user .............. (non root) user that the process will use for execution (required)
    -a apps .............. Comma-separated list of apps (vnext,phee,mifosx,infra) or 'all' (optional)
    -e environment ....... Cluster environment (local or remote, optional, default=local)
    -p provider .......... Cloud provider for remote deploy (aks|eks|oke). Implies -e remote. # GAZ-23
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
        echo "Error: Required options -m (mode) and -u (user) must be provided."
        showUsage
        exit 1
    fi

    if [[ "$k8s_user" == "root" ]]; then
        echo "Error: The specified user cannot be root. Please specify a non-root user."
        showUsage
        exit 1
    fi

    if [[ "$mode" != "deploy" && "$mode" != "cleanapps" && "$mode" != "cleanall" ]]; then
        echo "Error: Invalid mode '$mode'. Must be one of: deploy, cleanapps, cleanall."
        showUsage
        exit 1
    fi

    # --- GAZ-23 - validate provider and enforce environment=remote if provider is specified ---
    if [[ -n "$provider" ]]; then
        if [[ "$provider" != "aks" && "$provider" != "eks" && "$provider" != "oke" ]]; then
            echo "Error: Invalid provider '$provider'. Must be one of: aks, eks, oke."
            showUsage
            exit 1
        fi
        # If provider is specified and environment is not specified or is local, switch to remote with a warning since provider implies remote deployment
        if [[ -z "$environment" || "$environment" == "local" ]]; then
            logWithLevel "$INFO" "Provider specified ($provider). Switching environment to 'remote'."
            environment="remote"
        fi
    fi
    # ---------------------------------

    if [[ "$mode" == "deploy" || "$mode" == "cleanapps" ]]; then
        if [[ -z "$apps" ]]; then
            echo "No specific apps provided with -a flag or config file. Defaulting to 'all'."
            apps="all"
        fi
        # TODO -> ALL VALID APPS should be from enabled list from config.ini  
        local ALL_VALID_APPS="infra vnext phee mifosx all"
        local CORE_APPS="infra vnext phee mifosx"

        local current_apps_array
        IFS=' ' read -r -a current_apps_array <<< "$apps"
        echo "DEBUG TODO -> current_apps_array: ${current_apps_array[*]}"


        local found_all_keyword="false"
        local specific_apps_count=0

        for app_item in "${current_apps_array[@]}"; do
            if ! [[ " $ALL_VALID_APPS " =~ " $app_item " ]]; then
                echo "Error: Invalid app specified: '$app_item'. Must be one of: ${ALL_VALID_APPS// /, }."
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
            echo "Error: Duplicate applications specified in -a flag."
            showUsage
            exit 1
        fi

        if [[ "$found_all_keyword" == "true" ]]; then
            if [[ "$specific_apps_count" -gt 0 ]]; then
                echo "Error: Cannot combine 'all' with specific applications. If 'all' is specified, no other apps should be listed."
                showUsage
                exit 1
            fi
            apps="$CORE_APPS"
            logWithLevel "$INFO" "Expanded 'all' keyword to: $apps"
        fi

        echo "DEBUG : Apps to process: $apps"
        if [[ " $apps " =~ " infra " ]]; then
            if [[ "$mode" == "deploy" ]]; then
                # for mode = deploy ensure 'infra' is first app if present
                    apps="infra $(echo $apps | sed 's/infra//')"
                    apps=$(echo $apps | xargs) # trim any extra spaces
            else # mode = cleanapps
                # for mode = cleanapps ensure 'infra' is last app if present
                    apps="$(echo $apps | sed 's/infra//') infra"
                    apps=$(echo $apps | xargs) # trim any extra spaces
            fi  
        fi
        echo "DEBUG Final apps to process order: $apps"
    fi

    if [[ -n "$debug" && "$debug" != "true" && "$debug" != "false" ]]; then
        echo "Error: Invalid value for debug. Use 'true' or 'false'."
        showUsage
        exit 1
    fi

    if [[ -n "$redeploy" && "$redeploy" != "true" && "$redeploy" != "false" ]]; then
        echo "Error: Invalid value for redeploy. Use 'true' or 'false'."
        showUsage
        exit 1
    fi

    if [[ -n "$environment" && "$environment" != "local" && "$environment" != "remote" ]]; then
        echo "Error: Invalid environment '$environment'. Must be 'local' or 'remote'."
        showUsage
        exit 1
    fi

    if [[ "$environment" == "local" ]]; then
        # GAZ-23 - For local environment, validate that the OS is Ubuntu and version is supported, and that k8s_version is specified
        if [[ ! " $linux_os_list " =~ " Ubuntu " ]]; then
            echo "Error: Only Ubuntu is supported for LOCAL deployment."
            showUsage
            exit 1
        fi
        
        # we add here a check for ubuntu version only for local environment since remote environment may be any k8s cluster and we will not be running kind or minikube locally in that case so we do not need to validate ubuntu version for remote environment, rather than out of this check
        local os_version=$(lsb_release -r -s | cut -d'.' -f1)
        if [[ ! " $ubuntu_ok_versions_list " =~ " $os_version " ]]; then
            echo "Error: Ubuntu version '$os_version' not supported for local setup."
            showUsage
            exit 1
        fi
        if [[ -z "$k8s_version" ]]; then
            echo "Error: k8s_version must be specified for local environment."
            showUsage
            exit 1
        fi
    fi

    if [[ "$environment" == "remote" && -n "$kubeconfig_path" ]]; then
        if [[ ! -f "$kubeconfig_path" ]]; then
            echo "Error: kubeconfig_path '$kubeconfig_path' does not exist or is not a file."
            showUsage
            exit 1
        fi
    fi

    if [[ ! " $linux_os_list " =~ " Ubuntu " ]]; then
        echo "Error: Only Ubuntu is supported in linux_os_list: $linux_os_list."
        showUsage
        exit 1
    fi

    echo "TODO -> eliminate hardcoded defaults use only config.ini settings ????? "
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
    while getopts "m:k:d:a:v:u:r:f:e:p:hH" OPTION ; do
        case "${OPTION}" in
            f) options_map["config_file_path"]="${OPTARG}" ;;
            m) options_map["mode"]="${OPTARG}" ;;
            d) options_map["debug"]="${OPTARG}" ;;
            a) options_map["apps"]="${OPTARG}" ;;
            u) options_map["k8s_user"]="${OPTARG}" ;;
            r) options_map["redeploy"]="${OPTARG}" ;;
            e) options_map["environment"]="${OPTARG}" ;;
            p) options_map["provider"]="${OPTARG}" ;; # GAZ-23
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
    echo -e "${RED}Performing graceful clean up${RESET}"
    echo "Exiting via cleanUp function"
    exit 2
}

#------------------------------------------------------------------------------
# Function : trapCtrlc
# Description: Handles Ctrl-C (SIGINT) signal to perform cleanup.
#------------------------------------------------------------------------------
function trapCtrlc {
    echo
    echo -e "${RED}Ctrl-C caught...${RESET}"
    cleanUp
}

trap "trapCtrlc" 2


# Global variables that will hold the final configuration
mode=""
#k8s_user=""
apps=""
environment=""
provider="" # GAZ-23
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
    if [[ -n "${cmd_args_map["provider"]}" ]]; then provider="${cmd_args_map["provider"]}"; fi # GAZ-23

    validateInputs

    export CLOUD_PROVIDER="$provider" # GAZ-23 - make export in order to be available to other scripts

    if [ "$mode" == "deploy" ]; then
        echo -e "${YELLOW}"
        echo -e "======================================================================================================"
        echo -e "The deployment made by this script is currently recommended for demo, test and educational purposes "
        echo -e "======================================================================================================"
        echo -e "${RESET}"
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