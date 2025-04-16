#!/bin/bash

# Define variables for the charts
SCRIPT_DIR=$( cd $(dirname "$0") ; pwd )
#BPMN_DIR="$( cd $(dirname "$SCRIPT_DIR")/../repos/ph_template/orchestration/phlabs ; pwd )"
BPMN_DIR="$( cd $(dirname "$SCRIPT_DIR")/../orchestration/ ; pwd )"

HOST="https://zeebeops.mifos.gazelle.test/zeebe/upload"
DEBUG=false
TENANT="ph_bluebank"  # Default tenant

deploy() {
    local file="$1"
    local cmd="curl --insecure --location --request POST $HOST \
        --header 'Platform-TenantId:$TENANT' \
        --form 'file=@\"$file\"' \
        -s -o /dev/null -w '%{http_code}'"

    if [ "$DEBUG" = true ]; then
        echo "Executing: $cmd"
        http_code=$(eval $cmd)
        exit_code=$?
        echo "HTTP Code: $http_code"
        echo "Exit code: $exit_code"
    else
        http_code=$(eval $cmd)
        exit_code=$?
        
        if [ "$exit_code" -eq 0 ] && [ "$http_code" -eq 200 ]; then
            echo "File: $file - Upload successful"
        else
            echo "File: $file - Upload failed (HTTP Code: $http_code)"
        fi
    fi
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -f <file>   Specify a single file to upload.
  -t <tenant> Specify the tenant name (default: bluebank).
  -d          Enable debug mode for detailed output.
  -h          Show this help message.

Description:
  This script uploads BPMN files to a Zeebe instance. If no file is specified,
  it will upload all BPMN files from predefined locations.

Examples:
  $(basename "$0") -f myprocess.bpmn
  $(basename "$0") -t mytenant
EOF
    exit 0
}

# Parse command line arguments
while getopts ":f:t:dh" opt; do
    case $opt in
        f)
            SINGLE_FILE="$OPTARG"
            ;;
        t)
            TENANT="$OPTARG"
            ;;
        d)
            DEBUG=true
            ;;
        h)
            usage
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            exit 1
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            exit 1
            ;;
    esac
done

# If a single file is specified, upload only that file
if [ -n "$SINGLE_FILE" ]; then
    if [ -f "$SINGLE_FILE" ]; then
        deploy "$SINGLE_FILE"
    else
        echo "Error: File '$SINGLE_FILE' not found."
        exit 1
    fi
else
    # Deploy files from predefined locations
    #for location in "$BPMN_DIR/orchestration/feel/"*.bpmn "$BPMN_DIR/orchestration/feel/example/"*.bpmn; do
    echo "Deploying BPMN files from $BPMN_DIR/feel/"
    for location in "$BPMN_DIR/feel/"*.bpmn; do
        echo "Deploying BPMN file: $location"
        [ -e "$location" ] || continue  # Skip if no files match the glob
        deploy "$location"
        sleep 2
    done
fi
