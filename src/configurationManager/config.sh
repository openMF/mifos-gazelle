#!/usr/bin/env bash

########################################################################
# GLOBAL VARS
########################################################################
BASE_DIR=$(pwd)
APPS_DIR="$BASE_DIR/repos/"
CONFIG_DIR="$BASE_DIR/config/"
INFRA_NAMESPACE="infra"
INFRA_RELEASE_NAME="infra"
NGINX_VALUES_FILE="$CONFIG_DIR/nginx_values.yaml"

# Mojaloop vNext 
VNEXTBRANCH="beta1"
VNEXTREPO_DIR="vnext"
VNEXT_NAMESPACE="vnext"
VNEXT_REPO_LINK="https://github.com/mojaloop/platform-shared-tools.git"
VNEXT_LAYER_DIRS=("$APPS_DIR/vnext/packages/installer/manifests/crosscut" "$APPS_DIR/vnext/packages/installer/manifests/ttk" "$APPS_DIR/vnext/packages/installer/manifests/apps" "$APPS_DIR/vnext/packages/installer/manifests/reporting")
VNEXT_VALUES_FILE="$CONFIG_DIR/vnext_values.json"

#paymenthubee
PHBRANCH="master"
PHREPO_DIR="ph"
PH_NAMESPACE="paymenthub"
PH_RELEASE_NAME="phee"
PH_VALUES_FILE="$CONFIG_DIR/ph_values.yaml"
PH_REPO_LINK="https://github.com/openMF/ph-ee-env-labs.git"
PH_EE_ENV_TEMPLATE_REPO_LINK="https://github.com/openMF/ph-ee-env-template.git"
PH_EE_ENV_TEMPLATE_REPO_BRANCH="c4gt-gazelle-dev"
PH_EE_ENV_TEMPLATE_REPO_DIR="ph_template"

# Define Kubernetes service and MySQL connection details
MYSQL_SERVICE_NAME="mysql"  # Replace with your MySQL service name
MYSQL_SERVICE_PORT="3306"           # Replace with the MySQL service port
LOCAL_PORT="3307"                   # Local port to forward to
MAX_WAIT_SECONDS=60

# MySQL Connection Details
MYSQL_USER="root"
MYSQL_PASSWORD="ethieTieCh8ahv"
MYSQL_HOST="127.0.0.1"  # This is the localhost because we are port forwarding
SQL_FILE="$BASE_DIR/src/deployer/setup.sql"

#fineract / MifosX 
FIN_NAMESPACE="fineract"
FIN_MANIFESTS_DIR="$APPS_DIR/mifosx/kubernetes/manifests"
FIN_BRANCH="mifos-gazelle_1"
FIN_REPO_LINK="https://github.com/openMF/mifosx-docker.git"
FIN_REPO_DIR="mifosx"

########################################################################
# FUNCTIONS FOR CONFIGURATION MANAGEMENT
########################################################################
function replaceValuesInFiles() {
    local directories=("$@")
    local json_file="$VNEXT_VALUES_FILE"

    # Check if jq is installed, if not, exit with an error message
    if ! command -v jq &>/dev/null; then
        echo "Error: 'jq' is not installed. Please install it (https://stedolan.github.io/jq/) and make sure it's in your PATH."
        return 1
    fi

    # Check if the JSON file exists
    if [ ! -f "$json_file" ]; then
        echo "Error: JSON file '$json_file' does not exist."
        return 1
    fi

    # Read the JSON file and create an associative array
    declare -A replacements
    while IFS= read -r json_object; do
        local old_value new_value
        old_value=$(echo "$json_object" | jq -r '.old_value')
        new_value=$(echo "$json_object" | jq -r '.new_value')
        replacements["$old_value"]="$new_value"
    done < <(jq -c '.[]' "$json_file")

    # Loop through the directories and process each file
    for dir in "${directories[@]}"; do
        if [ -d "$dir" ]; then
            find "$dir" -type f | while read -r file; do
                local changed=false
                for old_value in "${!replacements[@]}"; do
                    if grep -q "$old_value" "$file"; then
                        #sed -i "s|$old_value|${replacements[$old_value]}|g" "$file"
                        #sed -i "s|.*$old_value.*|${replacements[$old_value]}|g" "$file"
                        sed -i "s|^\(.*\)$old_value.*|\1${replacements[$old_value]}|g" "$file"
                        changed=true
                    fi
                done
                if $changed; then
                    echo "Updated: $file"
                fi
            done
        else
            echo "Directory $dir does not exist."
        fi
    done
}

function configurevNext() {
  replaceValuesInFiles "${VNEXT_LAYER_DIRS[0]}" "${VNEXT_LAYER_DIRS[2]}" "${VNEXT_LAYER_DIRS[3]}"
}


function createSecret(){
  local namespace="$1"
  echo -e "Creating secrets in the $namespace namespace"
  if make secrets -e NAMESPACE="$namespace" >> /dev/null 2>&1 ; then
    echo -e "${GREEN}Created secrets in the $namespace namespace${RESET}"
    return 0
  else
    echo -e "${RED}Creating secrets in the $namespace namespace${RESET} failed"
    exit 1
  fi
}

function configurePH() {
  local ph_chart_dir=$1
  local previous_dir="$PWD"  # Save the current working directory
  echo -e "${BLUE}Configuring Payment Hub ${RESET}"

  cd $ph_chart_dir || exit 1

  # Check if make is installed
  if ! command -v make &> /dev/null; then
      logWithVerboseCheck $debug info "make is not installed. Installing ..."
      sudo apt update >> /dev/null 2>&1
      sudo apt install -y make >> /dev/null 2>&1
      logWithVerboseCheck $debug info "ok"
  else
      logWithVerboseCheck $debug info "make is installed. Proceeding to configure"
  fi
  # create secrets for paymenthub namespace and infra namespace
  cd es-secret || exit 1
  createSecret "$PH_NAMESPACE"
  createSecret "$INFRA_NAMESPACE"
  cd ..
  cd kibana-secret || exit 1
  createSecret "$PH_NAMESPACE"
  createSecret "$INFRA_NAMESPACE"
  cd ..
  # kubectl create secret generic moja-ph-redis --from-literal=redis-password="" -n "$PH_NAMESPACE"

  # check if the configuration was successful
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}Configuration of Paymenthub Successful${RESET}"
  else
    echo -e "${RED}Configuration of Paymenthub Failed${RESET}"
    exit 1
  fi

  # Return to the previous working directory
  cd "$previous_dir" || return 1
}

function configureFineract(){
  echo -e "${BLUE}Configuring fineract ${RESET}"
}