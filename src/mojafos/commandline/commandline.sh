#!/usr/bin/env bash

source ./src/mojafos/configurationManager/config.sh
source ./src/mojafos/environmentSetup/environmentSetup.sh
source ./src/mojafos/deployer/deployer.sh

function welcome {
  echo -e "${BLUE}"
  echo -e "███    ███  ██████       ██  █████  ███████  ██████  ███████ "
  echo -e "████  ████ ██    ██      ██ ██   ██ ██      ██    ██ ██      "
  echo -e "██ ████ ██ ██    ██      ██ ███████ █████   ██    ██ ███████ "
  echo -e "██  ██  ██ ██    ██ █   ██ ██   ██ ██      ██    ██      ██ "
  echo -e "██      ██  ██████   █████  ██   ██ ██       ██████  ███████ "
  echo -e "                                                              "
  echo -e "                                                              ${RESET}"
}

function showUsage {
  if [ $# -ne 0 ] ; then
		echo "Incorrect number of arguments passed to function $0"
		exit 1
	else
echo  "USAGE: $0 -m [mode] -u [user] -d [true/false]  
Example 1 : sudo $0  -m deploy -u \$USER -d true # install mojafos with debug mode and user \$USER
Example 2 : sudo $0  -m cleanup -u \$USER -d true # delete mojafos with debug mode and user \$USER
Example 3 : sudo $0  -m deploy -u \$USER -d false # install mojafos without debug mode and user \$USER

Options:
-m mode ............... install|delete (-m is required)
-u user................ user that the process will use for execution
-d debug............... debug mode. if set debug is true, if not set debug is false
-h|H .................. display this message
"
  fi
  
}

function getoptions {
  local mode_opt

  while getopts "m:k:d:a:f:e:u:hH" OPTION ; do
    case "${OPTION}" in
            m)	    mode_opt="${OPTARG}"
            ;;
            k)      k8s_distro="${OPTARG}"
            ;;
            d)      debug="${OPTARG}"
            ;;
            a)      apps="${OPTARG}"
            ;;
            f)      fineract_instansces="${OPTARG}"
            ;;
            e)      environment="${OPTARG}"
            ;;
            v)	    k8s_user_version="${OPTARG}"
            ;;
            u)      k8s_user="${OPTARG}"
            ;;
            h|H)	showUsage
                    exit 0
            ;;
            *)	echo  "unknown option"
                    showUsage
                    exit 1
            ;;
        esac
    done

  if [ -z "$mode_opt" ]; then
    echo "Error: Mode argument is required."
    showUsage
    exit 1
  fi

  if [ -z "$debug" ]; then
    debug=false
  fi

  mode="$mode_opt"
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
  getoptions "$@"
  if [ $mode == "deploy" ]; then
    echo -e "${YELLOW}"
    echo -e "===================================================================================="
    echo -e "The deployment made by this script is meant for demo purposes and not for production"
    echo -e "===================================================================================="
    echo -e "${RESET}"
    envSetupMain "$mode" "k3s" "1.26" "$environment"
    deployApps "$fineract_instansces" "$apps"
  elif [ $mode == "cleanup" ]; then
    logWithVerboseCheck $debug info "Cleaning up all traces of Mojafos"
    envSetupMain "$mode" "k3s" "1.26" "$environment"
  else
    showUsage
  fi
}

###########################################################################
# CALL TO MAIN
###########################################################################
main "$@"
