#!/bin/bash
# run.sh -- Main entry point for Mifos Gazelle deployment scripts

RUN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )" # the directory that this script is in 
export RUN_DIR 
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