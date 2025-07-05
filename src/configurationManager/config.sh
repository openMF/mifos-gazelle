#!/usr/bin/env bash

########################################################################
# GLOBAL VARS
########################################################################
BASE_DIR=$( cd $(dirname "$0") ; pwd )
APPS_DIR="$BASE_DIR/repos"
CONFIG_DIR="$BASE_DIR/config"
UTILS_DIR="$BASE_DIR/src/utils"
INFRA_NAMESPACE="infra"
INFRA_RELEASE_NAME="infra"
INFRA_CHART_DIR="$BASE_DIR/src/deployer/helm/infra" 
NGINX_VALUES_FILE="$CONFIG_DIR/nginx_values.yaml"
GAZELLE_DOMAIN="mifos.gazelle.test"

# Mojaloop vNext 
VNEXTBRANCH="beta1"
VNEXTREPO_DIR="vnext"
VNEXT_NAMESPACE="vnext"
VNEXT_REPO_LINK="https://github.com/mojaloop/platform-shared-tools.git"
VNEXT_LAYER_DIRS=("$APPS_DIR/vnext/packages/installer/manifests/crosscut" "$APPS_DIR/vnext/packages/installer/manifests/ttk" "$APPS_DIR/vnext/packages/installer/manifests/apps" "$APPS_DIR/vnext/packages/installer/manifests/reporting")
VNEXT_VALUES_FILE="$CONFIG_DIR/vnext_values.json"
VNEXT_MONGODB_DATA_DIR="$APPS_DIR/$VNEXTREPO_DIR/packages/deployment/docker-compose-apps/ttk_files/mongodb"
VNEXT_TTK_FILES_DIR="$APPS_DIR/$VNEXTREPO_DIR/packages/deployment/docker-compose-apps/ttk_files"

#PaymentHub EE 
PHBRANCH="master"
PHREPO_DIR="phlabs"
PH_NAMESPACE="paymenthub"
PH_RELEASE_NAME="phee"
PH_VALUES_FILE="$CONFIG_DIR/ph_values.yaml"
PH_REPO_LINK="https://github.com/openMF/ph-ee-env-labs.git"
PH_EE_ENV_TEMPLATE_REPO_LINK="https://github.com/devarsh10/ph-ee-env-template.git"
#PH_EE_ENV_TEMPLATE_REPO_BRANCH="v1.13.0-gazelle-1.1.0"
PH_EE_ENV_TEMPLATE_REPO_BRANCH="devarsh-arm-work"
PH_EE_ENV_TEMPLATE_REPO_DIR="ph_template"

# Define Kubernetes service and MySQL connection details
MYSQL_SERVICE_NAME="mysql"  # Replace with your MySQL service name
MYSQL_SERVICE_PORT="3306"           # Replace with the MySQL service port
LOCAL_PORT="3307"                   # Local port to forward to
MAX_WAIT_SECONDS=60

# MySQL Connection Details
# MYSQL_USER="root"
# MYSQL_PASSWORD="ethieTieCh8ahv"
MYSQL_HOST="127.0.0.1"  # This is the localhost because we are port forwarding
SQL_FILE="$BASE_DIR/src/deployer/setup.sql"

#MifosX 
MIFOSX_NAMESPACE="mifosx"
MIFOSX_MANIFESTS_DIR="$APPS_DIR/mifosx/kubernetes/manifests"
MIFOSX_BRANCH="devarsh-arm-work-mifosx"
MIFOSX_REPO_LINK="https://github.com/devarsh10/mifosx-platform.git"
MIFOSX_REPO_DIR="mifosx"

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
                    echo "Updated: $file" >> /dev/null 2>&1
                fi
            done
        else
            echo "Directory $dir does not exist."
        fi
    done
}

function configurevNext() {
  replaceValuesInFiles "${VNEXT_LAYER_DIRS[0]}" "${VNEXT_LAYER_DIRS[2]}" "${VNEXT_LAYER_DIRS[3]}"
  # Iterate over each directory in VNEXT_LAYER_DIRS
  for dir in "${VNEXT_LAYER_DIRS[@]}"; do
    # Find all YAML files in the directory
    find "$dir" -type f -name "*.yaml" | while read -r file; do
      # Perform the in-place substitution for ingressClassName
      perl -pi -e 's/ingressClassName:\s*nginx-ext/ingressClassName: nginx/' "$file"
      
      # Perform the in-place substitution for domain name .local to mifos.gazelle.test
      perl -pi -e 's/- host:\s*(\S+)\.local/- host: $1.mifos.gazelle.test/' "$file"
      perl -pi -e 's/(\S+)bank\.local/$1bank.mifos.gazelle.test/' "$file"

    done
  done
}

function configureMifosx(){
  echo -e "${BLUE}Configuring MifosX ${RESET}"
}