#!/usr/bin/env bash

source "$RUN_DIR/src/mojafos/configurationManager/config.sh"
source "$RUN_DIR/src/mojafos/environmentSetup/environmentSetup.sh"
source "$RUN_DIR/src/mojafos/deployer/deployer.sh"

echo "in commandline: RUN_DIR is $RUN_DIR"


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
echo  "USAGE: $0 -m [mode] -u [user] -a [apps] -e [environment] -d [true/false]  
Example 1 : sudo $0  -m deploy -u \$USER -d true # install mojafos with debug mode and user \$USER
Example 2 : sudo $0  -m cleanapps -u \$USER -d true # delete apps leave environment with debug mode and user \$USER
Example 3 : sudo $0  -m cleanall -u \$USER # delete all apps, and all kubernetes artifacts and server
Example 4 : sudo $0  -m deploy -u \$USER  -a ph # install PHEE only, user \$USER
Example 5 : sudo $0  -m deploy -u \$USER  -a all # install all apps i.e. moja, phee and fineract user \$USER

Options:
-m mode ............... deploy|cleanapps|cleanall (-m is required)
-u user................ user that the process will use for execution (-u required)
-a apps................ moja|ph|fin (apps that can be independantly deployed -a required )
-e environment ........ currently local is the only value supported and is the default
-d debug............... debug mode. if set debug is true, if not set debug is false
-h|H .................. display this message
"
  fi
  
}

function getoptions {
    local mode_opt
    while getopts "m:k:da:f:e:v:u:hH" OPTION ; do
        case "${OPTION}" in
            m) mode_opt="${OPTARG}" ;;
            k) k8s_distro="${OPTARG}" ;;
            d) debug="${OPTARG}" ;;
            a) apps="${OPTARG}" ;;
            f) fineract_instances="${OPTARG}" ;;
            e) environment="${OPTARG}" ;;
            v) k8s_user_version="${OPTARG}" ;;
            u) k8s_user="${OPTARG}" ;;
            h|H) showUsage
                 exit 0 ;;
            *) echo "unknown option"
               showUsage
               exit 1 ;;
        esac
    done

    if [ -z "$mode_opt" ]; then
      echo "Error: Mode argument is required."
      showUsage
      exit 1
    fi

    # if [ -z "$k8s_user" ]; then
    #   echo "Error: User argument is required."
    #   showUsage
    #   exit 1
    # fi

    if [ -z "$debug" ]; then
      debug=false
    fi

    mode="$mode_opt"

    if [ -z "$environment" ]; then
      echo "Warning: -e flag ignored as currently mifos-gazelle only supports deployment to local k3s environment"
  
    fi

    environment="local"   # hardcoded for the moment but EKS,AKS,GCP etc should be enabled
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
  echo "APPS=$apps"
  echo "fineract_instances=$fineract_instances"

  if [ $mode == "deploy" ]; then
    echo -e "${YELLOW}"
    echo -e "======================================================================================================"
    echo -e "The deployment made by this script is currently suitable only for demo purposes and not for production"
    echo -e "======================================================================================================"
    echo -e "${RESET}"
    envSetupMain "$mode" "k3s" "1.30" "$environment"
    echo "deployApps $fineract_instances $apps"
    deployApps "$fineract_instances" "$apps"
  elif [ $mode == "cleanapps" ]; then  
    logWithVerboseCheck $debug info "Cleaning up Mojafos applications only"
    envSetupMain "$mode" "k3s" "1.30" "$environment"
  elif [ $mode == "cleanall" ]; then
    logWithVerboseCheck $debug info "Cleaning up all traces of Mojafos"
    envSetupMain "$mode" "k3s" "1.30" "$environment"
  else
    showUsage
  fi
}

###########################################################################
# CALL TO MAIN
###########################################################################
main "$@"