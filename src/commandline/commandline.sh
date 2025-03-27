#!/usr/bin/env bash

source "$RUN_DIR/src/configurationManager/config.sh"
source "$RUN_DIR/src/environmentSetup/environmentSetup.sh"
source "$RUN_DIR/src/deployer/deployer.sh"

function welcome {
    echo -e "${BLUE}"
    echo -e " ██████   █████  ███████ ███████ ██      ██      ███████ "
    echo -e "██       ██   ██    ███  ██      ██      ██      ██      "
    echo -e "██   ███ ███████   ███   █████   ██      ██      █████   "
    echo -e "██    ██ ██   ██  ███    ██      ██      ██      ██      "
    echo -e " ██████  ██   ██ ███████ ███████ ███████ ███████ ███████ "
    echo -e "${RESET}"
}
function showUsage {
    echo "
USAGE: $0 -m [mode] -u [user] -a [apps] -e [environment] -d [true/false]  
Example 1 : sudo $0 -m deploy -u \$USER -d true     # install mifos-gazelle with debug mode and user \$USER
Example 2 : sudo $0 -m cleanapps -u \$USER -d true  # delete apps, leave environment with debug mode and user \$USER
Example 3 : sudo $0 -m cleanall -u \$USER           # delete all apps, all Kubernetes artifacts, and server
Example 4 : sudo $0 -m deploy -u \$USER -a phee     # install PHEE only, user \$USER
Example 5 : sudo $0 -m deploy -u \$USER -a all      # install all apps (vNext, PHEE, and MifosX) with user \$USER

Options:
  -m mode ................ deploy|cleanapps|cleanall  (required)
  -u user ................ (non root) user that the process will use for execution (required)
  -a apps ................ vnext|phee|mifosx (apps that can be independently deployed) (optional)
  -e environment ......... currently, 'local' is the only value supported and is the default (optional)
  -d debug ............... enable debug mode (true|false) (optional default=false)
  -r redeploy ............ force redeployment of apps (true|false) (optional, default=true)
  -h|H ................... display this message
"
}

function validateInputs {
    if [[ -z "$mode" || -z "$k8s_user" ]]; then
        echo "Error: Required options -m (mode) and -u (user) must be provided."
        showUsage
        exit 1
    fi

    if [[ "$mode" != "deploy" && "$mode" != "cleanapps" && "$mode" != "cleanall" ]]; then
        echo "Error: Invalid mode '$mode'. Must be one of: deploy, cleanapps, cleanall."
        showUsage
        exit 1
    fi

    if [[ "$mode" == "deploy" || "$mode" == "cleanapps" ]]; then
        if [[ -z "$apps" ]]; then
            echo "No specific apps provided with -a flag. Defaulting to 'all'."
            apps="all"
        elif [[ "$apps" != "infra" && "$apps" != "vnext" && "$apps" != "phee" && "$apps" != "mifosx" && "$apps" != "all" ]]; then
            echo "Error: Invalid value for apps. Must be one of: infra, vnext, phee, mifosx, all."
            showUsage
            exit 1
        fi
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

    # Set default values
    environment="${environment:-local}"
    debug="${debug:-false}"
    redeploy="${redeploy:-true}"
}


function getOptions {
    while getopts "m:k:d:a:e:v:u:r:hH" OPTION ; do
        case "${OPTION}" in
            m) mode="${OPTARG}" ;;
            k) k8s_distro="${OPTARG}" ;;
            d) debug="${OPTARG}" ;;
            a) apps="${OPTARG}" ;;
            v) k8s_user_version="${OPTARG}" ;;
            u) k8s_user="${OPTARG}" ;;
            r) redeploy="${OPTARG}" ;;
            h|H) showUsage
                 exit 0 ;;
            *) echo "Unknown option: -${OPTION}"
               showUsage
               exit 1 ;;
        esac
    done
}

# this function is called when Ctrl-C is sent
function cleanUp ()
{
    # perform cleanup here
    echo -e "${RED}Performing graceful clean up${RESET}"

    mode="cleanup"
    echo "Doing cleanup" 
    envSetupMain "$mode" "k3s" "1.26" "$environment"

    # exit shell script with error code 2
    # if omitted, shell script will continue execution
    exit 2
}

function trapCtrlc {
  echo
  echo -e "${RED}Ctrl-C caught...${RESET}"
  cleanUp
}

# initialise trap to call trap_ctrlc function
# when signal 2 (SIGINT) is received
trap "trapCtrlc" 2

###########################################################################
# MAIN
###########################################################################
function main {
  welcome 
  getOptions "$@"
  validateInputs

  if [ $mode == "deploy" ]; then
    echo -e "${YELLOW}"
    echo -e "======================================================================================================"
    echo -e "The deployment made by this script is currently recommended for demo, test and educational purposes "
    echo -e "======================================================================================================"
    echo -e "${RESET}"
    envSetupMain "$mode" "k3s" "1.31" "$environment"
    deployApps "$mifosx_instances" "$apps" "$redeploy" 
  elif [ $mode == "cleanapps" ]; then  
    logWithVerboseCheck $debug info "Cleaning up Mifos Gazelle applications only"
    deleteApps "$mifosx_instances" "$apps"
  elif [ $mode == "cleanall" ]; then
    logWithVerboseCheck $debug info "Cleaning up all traces of Mifos Gazelle "
    deleteApps "$mifosx_instances" "all"
    envSetupMain "$mode" "k3s" "1.31" "$environment"
  else
    showUsage
  fi
}

###########################################################################
# CALL TO MAIN
###########################################################################
main "$@"