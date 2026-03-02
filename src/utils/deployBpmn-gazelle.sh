#!/bin/bash
# Define variables for the charts
SCRIPT_DIR=$( cd $(dirname "$0") ; pwd )
config_dir="$( cd $(dirname "$SCRIPT_DIR")/../config ; pwd )"
default_config_ini="$config_dir/config.ini"
config_ini="$default_config_ini"  # Will be overridden if -c is specified
BPMN_DIR="$( cd $(dirname "$SCRIPT_DIR")/../orchestration/ ; pwd )"
DEBUG=false
TENANT="greenbank"  # Default tenant TODO does this actually do anything 

deploy() {
    local file="$1"
    local filename=$(basename "$file")

    echo "Uploading: $filename to tenant: $TENANT"

    local http_code
    local response

    # Capture both response body and HTTP code
    response=$(curl --insecure --location --request POST "$HOST" \
        --header "Platform-TenantId:$TENANT" \
        --form "file=@\"$file\"" \
        --write-out "\n%{http_code}" \
        --silent \
        --show-error 2>&1)

    local exit_code=$?

    # Extract HTTP code (last line) and response body (everything else)
    http_code=$(echo "$response" | tail -1)
    local response_body=$(echo "$response" | head -n -1)

    if [ "$DEBUG" = true ]; then
        echo "DEBUG: HTTP Code: $http_code"
        echo "DEBUG: Exit code: $exit_code"
        echo "DEBUG: Response: $response_body"
    fi

    if [ "$exit_code" -ne 0 ]; then
        echo "ERROR: curl failed with exit code $exit_code"
        echo "ERROR: $response_body"
        return 1
    fi

    if [ "$http_code" -eq 200 ] || [ "$http_code" -eq 201 ]; then
        echo "SUCCESS: $filename uploaded to $TENANT"
        return 0
    else
        echo "ERROR: Upload failed (HTTP $http_code)"
        if [ -n "$response_body" ]; then
            echo "ERROR: $response_body"
        fi
        return 1
    fi
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -c <config> Specify the config.ini file to use (default: $default_config_ini).
  -f <file>   Specify a single file to upload.
  -t <tenant> Specify the tenant name (default: greenbank).
  -d          Enable debug mode for detailed output.
  -h          Show this help message.

Description:
  This script uploads BPMN files to a Zeebe instance. If no file is specified,
  it will upload all BPMN files from predefined locations.

Examples:
  $(basename "$0") -c /path/to/custom.ini -f myprocess.bpmn
  $(basename "$0") -c /path/to/custom.ini -t mytenant
  $(basename "$0") -f myprocess.bpmn
EOF
    exit 0
}

# Parse command line arguments
while getopts ":c:f:t:dh" opt; do
    case $opt in
        c)
            config_ini="$OPTARG"
            if [ ! -f "$config_ini" ]; then
                echo "Error: Config file '$config_ini' not found." >&2
                exit 1
            fi
            ;;
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

# Extract domain from the config file (after -c has been processed)
domain=$(grep -E "^GAZELLE_DOMAIN\s*=" "$config_ini" | cut -d '=' -f2 | tr -d " " )

if [ -z "$domain" ]; then
    echo "ERROR: GAZELLE_DOMAIN not found in $config_ini" >&2
    echo "ERROR: Make sure config file has: GAZELLE_DOMAIN=<your-domain>" >&2
    exit 1
fi

# Check if running inside Kubernetes pod (check for service account token)
if [ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
    # Running inside a pod, use internal service
    HOST="http://ph-ee-zeebe-ops.paymenthub.svc.cluster.local/zeebe/upload"
    echo "================================================================"
    echo "Zeebe BPMN Deployment Tool (Kubernetes Internal)"
    echo "================================================================"
else
    # Running externally, use ingress
    HOST="https://zeebeops.$domain/zeebe/upload"
    echo "================================================================"
    echo "Zeebe BPMN Deployment Tool"
    echo "================================================================"
fi

echo "Config file: $config_ini"
echo "Domain: $domain"
echo "Endpoint: $HOST"
echo "Tenant: $TENANT"
echo "================================================================"

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
    echo "Deploying BPMN files from $BPMN_DIR/feel/"
    for location in "$BPMN_DIR/feel/"*.bpmn; do
        echo "Deploying BPMN file: $location"
        [ -e "$location" ] || continue  # Skip if no files match the glob
        deploy "$location"
        sleep 2
    done
fi