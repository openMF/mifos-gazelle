#!/bin/bash

# Define variables for the charts
SCRIPT_DIR=$( cd $(dirname "$0") ; pwd )
BPMN_DIR="$( cd $(dirname "$SCRIPT_DIR")/../repos/phlabs ; pwd )"

HOST="https://zeebeops.mifos.gazelle.test/zeebe/upload"
DEBUG=false

deploy() {
    local file="$1"
    local cmd="curl --insecure --location --request POST $HOST \
        --header 'Platform-TenantId: gorilla' \
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

# Parse command line arguments
while getopts ":df:" opt; do
    case $opt in
        d)
            DEBUG=true
            ;;
        f)
            SINGLE_FILE="$OPTARG"
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
    for location in "$BPMN_DIR/orchestration/feel/"*.bpmn "$BPMN_DIR/orchestration/feel/example/"*.bpmn; do
        [ -e "$location" ] || continue  # Skip if no files match the glob
        deploy "$location"
        #sleep 20
    done
fi