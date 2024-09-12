#!/bin/bash

RUN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"  # the directory that this script is in 
echo "RUN_DIR is $RUN_DIR"
BASE_DIR="$( cd $(dirname "$RUN_DIR") ; pwd )"
echo "BASE_DIR is $BASE_DIR"

function welcome {
    echo -e "\e[33mWARNING: In case you start getting service unavailable errors, please follow the Step 5 from the POSTMAN_SETPUP.md file.\e[0m"
    echo -e "\e[33mWARNING: This script will only work if you have run the deployment atleast once successfully.\e[0m"
    echo -e "\e[33mWARNING: This script uses the directory repos/phlabs/orchestration/feel/ to upload the BPMN diagrams to zeebe operations service.\e[0m"
}

# Check if the script is run with root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Check if IP address is provided
if [ $# -lt 1 ]; then
    echo "Usage: $0 <ip_address> [-o true/false]"
    echo "  -o: Override option. If true, overrides existing entry for the IP. Default is false."
    exit 1
fi

welcome

# Initialize variables
ip_address=$1
override=false

# Parse arguments
shift
while [[ $# -gt 0 ]]; do
    case $1 in
        -o)
            if [[ $2 == "true" ]]; then
                override=true
            fi
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Hardcoded list of hostnames
hostnames=(
    "vnextadmin.local"
    "elasticsearch.local"
    "kibana.local"
    "mongoexpress.local"
    "kafkaconsole.local"
    "fspiop.local"
    "bluebank.local"
    "greenbank.local"
    "mifos.local"
    "ops.local"
    "ops-bk.local"
    "bulk-connector.local"
    "messagegateway.local"
    "minio.local"
    "ams-mifos.local"
    "bill-pay.local"
    "channel.local"
    "channel-gsma.local"
    "crm.local"
    "mockpayment.local"
    "mojaloop.local"
    "identity-mapper.local"
    "analytics.local"
    "vouchers.local"
    "zeebeops.local"
    "notifications.local"
)

# Function to add or update hosts
add_or_update_hosts() {
    local ip=$1
    local hosts="${hostnames[*]}"
    local existing_line=$(grep -E "^$ip[[:space:]]" /etc/hosts)

    if [ -n "$existing_line" ]; then
        if $override; then
            sed -i "/^$ip[[:space:]]/c\\$ip $hosts" /etc/hosts
            echo "Updated existing entry for $ip with hardcoded hostnames."
        else
            echo "$ip $hosts" >> /etc/hosts
            echo "Added new entry for $ip as the override option was set to false."
        fi
    else
        echo "$ip $hosts" >> /etc/hosts
        echo "Added new entry for $ip."
    fi
}

# Call function with parsed arguments
add_or_update_hosts "$ip_address"

echo -e "\e[32mFinished updating /etc/hosts\e[0m"

# Uploading BPMN Diagrams 

HOST="http://zeebeops.local/zeebe/upload/"
deploy(){
    cmd="curl --insecure --location --connect-timeout 60 --max-time 120 --request POST $HOST \
    --header 'Platform-TenantId: gorilla' \
    --form 'file=@\"$PWD/$1\"'"
    echo $cmd
    eval $cmd 
    #If curl response is not 200 it should fail the eval cmd
}

LOC1="$BASE_DIR/repos/ph_env_labs/orchestration/feel/*.bpmn"
#LOC1=../src/deployer/apps/ph_env_labs/orchestration/feel/*.bpmn
for f in $LOC1; do
    deploy $f
done

LOC2="$BASE_DIR/repos/ph_env_labs/orchestration/feel/example/*.bpmn"
#LOC2=../src/deployer/apps/ph_env_labs/orchestration/feel/example/*.bpmn
for f in $LOC2; do
    deploy $f
done

# write finished message in green color
echo -e "\e[32mFinished uploading BPMN diagrams\e[0m"
