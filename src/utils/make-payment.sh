#!/usr/bin/env bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RESET='\033[0m'

# API Configuration placeholders (will be set after parsing config)
TRANSFER_URL=""
MIFOS_CORE_API=""
MIFOS_AUTH="mifos:password"

function usage() {
cat <<EOF
Usage: $0 [-f <config_file>] [-p <payer_msisdn>] [-r <payee_msisdn>] [-t <tenant_id>] [-d <payee_dfsp_id>] [-v]
 -c Path to config.ini file (default: ../config/config.ini) [optional]
 -p Payer MSISDN (default: auto-detect first client from payer tenant) [optional]
 -r Payee MSISDN (default: auto-detect first client from payee tenant) [optional]
 -t Platform-TenantId (default: greenbank) [optional]
 -d X-PayeeDFSP-ID (default: bluebank) [optional]
 -v Enable debug/verbose mode [optional]
 -h Show this help message

Note: If -p or -r are not provided, the script will automatically query for the
      first available client in the respective tenant.
EOF
}

# Function to lookup client name by MSISDN
function lookup_client_name() {
    local msisdn="$1"
    local tenant_id="$2"
    local client_type="$3"  # "payer" or "payee" for debugging
    
    echo "🔍 Looking up $client_type for MSISDN: $msisdn in tenant: $tenant_id..." >&2
    
    # Build the curl command
    local curl_cmd="curl -sk -u \"$MIFOS_AUTH\" -H \"Fineract-Platform-TenantId: $tenant_id\" \"$MIFOS_CORE_API/clients?phoneNumber=$msisdn\""
    
    # Show curl command if debug is enabled
    if [[ "$debug" == true ]]; then
        echo -e "${BLUE}DEBUG - Curl command:${RESET}" >&2
        echo "$curl_cmd" >&2
        echo "" >&2
    fi
    
    # Make API call to get client details
    local response
    response=$(curl -sk -u "$MIFOS_AUTH" -H "Fineract-Platform-TenantId: $tenant_id" \
        "$MIFOS_CORE_API/clients?phoneNumber=$msisdn" 2>/dev/null || echo "")
    
    # Show raw response if debugging is enabled
    if [[ "$debug" == true ]]; then
        echo -e "${BLUE}DEBUG - Raw API Response:${RESET}" >&2
        echo "$response" >&2
        echo "" >&2
    fi
    
    if [[ -z "$response" ]] || [[ "$response" == *"error"* ]] || [[ "$response" == *"Authentication"* ]]; then
        echo "Unknown (API Error)"
        return 1
    fi
    
    # Check if response contains any clients
    if [[ "$response" == *"\"totalFilteredRecords\":0"* ]] || [[ "$response" == "[]" ]]; then
        echo "Unknown (Not Found in $tenant_id)"
        return 1
    fi
    
    # Parse JSON to extract display name
    # The API returns clients in pageItems array, find the one matching our MSISDN
    local display_name=""

    # Extract the client object matching our MSISDN
    # Look for displayName that appears before the matching mobileNo
    local json_section=""
    json_section=$(echo "$response" | grep -o "\"displayName\":\"[^\"]*\"[^}]*\"mobileNo\":\"$msisdn\"" | head -n1 || echo "")

    if [[ -n "$json_section" ]]; then
        display_name=$(echo "$json_section" | grep -o '"displayName":"[^"]*"' | sed 's/"displayName":"\([^"]*\)"/\1/')
    fi

    # If that didn't work, fall back to the first displayName (for backward compatibility)
    if [[ -z "$display_name" ]]; then
        display_name=$(echo "$response" | grep -o '"displayName":"[^"]*"' | head -n1 | sed 's/"displayName":"\([^"]*\)"/\1/')
    fi
    
    if [[ "$debug" == true ]]; then
        echo -e "${BLUE}DEBUG - Extracted name: '$display_name'${RESET}" >&2
        echo "" >&2
    fi
    
    if [[ -n "$display_name" ]] && [[ "$display_name" != "null" ]]; then
        echo "$display_name"
        return 0
    else
        echo "Unknown (Name Not Found in $tenant_id)"
        return 1
    fi
}

# Function to get first client MSISDN from tenant
function get_first_client_msisdn() {
    local tenant="$1"
    local client_type="$2"  # "payer" or "payee" for logging

    echo "🔍 Querying first $client_type client in tenant: $tenant..." >&2

    local response
    response=$(curl -sk -u "$MIFOS_AUTH" -H "Fineract-Platform-TenantId: $tenant" \
        "$MIFOS_CORE_API/clients?limit=1&orderBy=id&sortOrder=ASC" 2>/dev/null || echo "")

    if [[ "$debug" == true ]]; then
        echo -e "${BLUE}DEBUG - First client API response:${RESET}" >&2
        echo "$response" >&2
        echo "" >&2
    fi

    if [[ -z "$response" ]] || [[ "$response" == *"error"* ]]; then
        echo "" >&2
        return 1
    fi

    # Extract mobile number from first client in pageItems
    local msisdn
    msisdn=$(echo "$response" | grep -o '"mobileNo":"[^"]*"' | head -n1 | sed 's/"mobileNo":"\([^"]*\)"/\1/')

    if [[ -n "$msisdn" ]] && [[ "$msisdn" != "null" ]]; then
        echo "$msisdn"
        return 0
    else
        echo "" >&2
        return 1
    fi
}

# Defaults
SCRIPT_DIR=$( cd $(dirname "$0") ; pwd )
default_config_dir="$( cd $(dirname "$SCRIPT_DIR")/../config ; pwd )"
default_config_ini="$default_config_dir/config.ini"
config_ini=""  # Will be set after parsing options

payer_msisdn=""  # Will be auto-detected from greenbank tenant if not provided
payee_msisdn=""  # Will be auto-detected from bluebank tenant if not provided
tenant_id="greenbank"
payee_dfsp_id="bluebank"
debug=false

# Parse options
while getopts ":c:p:r:t:d:vh" opt; do
    case $opt in
        c) config_ini="$OPTARG" ;;
        p) payer_msisdn="$OPTARG" ;;
        r) payee_msisdn="$OPTARG" ;;
        t) tenant_id="$OPTARG" ;;
        d) payee_dfsp_id="$OPTARG" ;;
        v) debug=true ;;
        h) usage; exit 0 ;;
        \?) echo "Invalid option: -$OPTARG" >&2; usage; exit 1 ;;
        :) echo "Option -$OPTARG requires an argument." >&2; usage; exit 1 ;;
    esac
done

# Set config file to default if not provided
if [[ -z "$config_ini" ]]; then
    config_ini="$default_config_ini"
fi

# Verify config file exists
if [[ ! -f "$config_ini" ]]; then
    echo -e "${RED}Error: Config file not found: $config_ini${RESET}" >&2
    exit 1
fi

# Show which config file is being used if debug is enabled
if [[ "$debug" == true ]]; then
    echo -e "${BLUE}DEBUG - Using config file: $config_ini${RESET}"
    echo ""
fi

# Read GAZELLE_DOMAIN from config file
GAZELLE_DOMAIN=$(grep GAZELLE_DOMAIN "$config_ini" | cut -d '=' -f2 | tr -d " " )
echo "🔧 GAZELLE_DOMAIN: $GAZELLE_DOMAIN" 

if [[ -z "$GAZELLE_DOMAIN" ]]; then
    echo -e "${RED}Error: GAZELLE_DOMAIN not found in config file: $config_ini${RESET}" >&2
    exit 1
fi

# Set API URLs now that we have the domain
TRANSFER_URL="https://channel.$GAZELLE_DOMAIN/channel/transfer"
MIFOS_CORE_API="http://mifos.$GAZELLE_DOMAIN/fineract-provider/api/v1"

if [[ "$debug" == true ]]; then
    echo -e "${BLUE}DEBUG - GAZELLE_DOMAIN: $GAZELLE_DOMAIN${RESET}"
    echo -e "${BLUE}DEBUG - TRANSFER_URL: $TRANSFER_URL${RESET}"
    echo -e "${BLUE}DEBUG - MIFOS_CORE_API: $MIFOS_CORE_API${RESET}"
    echo ""
fi

# Auto-detect payer MSISDN if not provided
if [[ -z "$payer_msisdn" ]]; then
    echo "🔍 Auto-detecting payer MSISDN from tenant: $tenant_id..."
    set +e
    payer_msisdn=$(get_first_client_msisdn "$tenant_id" "payer")
    detection_status=$?
    set -e
    if [[ $detection_status -ne 0 ]] || [[ -z "$payer_msisdn" ]]; then
        echo -e "${RED}Error: Could not auto-detect payer MSISDN from tenant $tenant_id${RESET}" >&2
        echo -e "${RED}Please ensure clients exist or specify -p <payer_msisdn>${RESET}" >&2
        exit 1
    fi
    echo "✓ Auto-detected payer MSISDN: $payer_msisdn"
    echo ""
fi

# Auto-detect payee MSISDN if not provided
if [[ -z "$payee_msisdn" ]]; then
    echo "🔍 Auto-detecting payee MSISDN from tenant: $payee_dfsp_id..."
    set +e
    payee_msisdn=$(get_first_client_msisdn "$payee_dfsp_id" "payee")
    detection_status=$?
    set -e
    if [[ $detection_status -ne 0 ]] || [[ -z "$payee_msisdn" ]]; then
        echo -e "${RED}Error: Could not auto-detect payee MSISDN from tenant $payee_dfsp_id${RESET}" >&2
        echo -e "${RED}Please ensure clients exist or specify -r <payee_msisdn>${RESET}" >&2
        exit 1
    fi
    echo "✓ Auto-detected payee MSISDN: $payee_msisdn"
    echo ""
fi

# Lookup client names
echo -e "${BLUE}=== Client Lookup ===${RESET}"
set +e  # Temporarily disable exit on error
payer_name=$(lookup_client_name "$payer_msisdn" "$tenant_id" "payer")
payer_lookup_status=$?
set -e  # Re-enable exit on error
if [[ $payer_lookup_status -ne 0 ]]; then
    echo -e "${RED}Error: Unable to find payer with MSISDN $payer_msisdn in tenant $tenant_id${RESET}" >&2
    exit 1
fi

# For payee, we need to determine the correct tenant
# If payee_dfsp_id is different from tenant_id, use payee_dfsp_id as tenant
payee_tenant="$tenant_id"
if [[ "$payee_dfsp_id" != "$tenant_id" ]]; then
    payee_tenant="$payee_dfsp_id"
fi

set +e  # Temporarily disable exit on error
payee_name=$(lookup_client_name "$payee_msisdn" "$payee_tenant" "payee")
payee_lookup_status=$?
set -e  # Re-enable exit on error
if [[ $payee_lookup_status -ne 0 ]]; then
    echo -e "${RED}Error: Unable to find payee with MSISDN $payee_msisdn in tenant $payee_tenant${RESET}" >&2
    exit 1
fi

# Display payment details
echo -e "${BLUE}=== Payment Details ===${RESET}"
echo -e "${YELLOW}Payer:${RESET} $payer_name ($payer_msisdn) [Tenant: $tenant_id]"
echo -e "${YELLOW}Payee:${RESET} $payee_name ($payee_msisdn) [Tenant: $payee_tenant]"
echo -e "${YELLOW}Tenant ID:${RESET} $tenant_id"
echo -e "${YELLOW}Payee DFSP ID:${RESET} $payee_dfsp_id"
echo ""

# Prompt for amount with validation
while true; do
    read -rp "Enter amount to transfer (0–500): " amount
    if [[ "$amount" =~ ^[0-9]+$ ]] && (( amount >= 0 && amount <= 500 )); then
        break
    else
        echo "❌ Invalid amount. Please enter a number between 0 and 500."
    fi
done

# Display final confirmation
echo ""
echo -e "${BLUE}=== Transfer Summary ===${RESET}"
echo -e "${YELLOW}From:${RESET} $payer_name ($payer_msisdn)"
echo -e "${YELLOW}To:${RESET} $payee_name ($payee_msisdn)"
echo -e "${YELLOW}Amount:${RESET} \$${amount} USD"
echo ""

# Generate unique correlation ID
correlation_id=$(uuidgen)

# Build JSON payload
json_payload=$(cat <<EOF
{
    "payer": {
        "partyIdInfo": {
            "partyIdType": "MSISDN",
            "partyIdentifier": "$payer_msisdn"
        }
    },
    "payee": {
        "partyIdInfo": {
            "partyIdType": "MSISDN",
            "partyIdentifier": "$payee_msisdn"
        }
    },
    "amount": {
        "amount": $amount,
        "currency": "USD"
    }
}
EOF
)

# Perform cURL POST and capture HTTP status
echo "📤 Sending transfer request..."

# Build the curl command for the transfer
transfer_curl_cmd="curl -sk -w \"\\n%{http_code}\" -X POST \"$TRANSFER_URL\" \
-H \"Platform-TenantId: $tenant_id\" \
-H \"X-PayeeDFSP-ID: $payee_dfsp_id\" \
-H \"X-CorrelationID: $correlation_id\" \
-H \"Content-Type: application/json\" \
-H \"Accept: */*\" \
-d '$json_payload'"

# Show transfer curl command if debug is enabled
if [[ "$debug" == true ]]; then
    echo -e "${BLUE}DEBUG - Transfer curl command:${RESET}"
    echo "$transfer_curl_cmd"
    echo ""
fi

response=$(curl -sk -w "\n%{http_code}" -X POST "$TRANSFER_URL" \
    -H "Platform-TenantId: $tenant_id" \
    -H "X-PayeeDFSP-ID: $payee_dfsp_id" \
    -H "X-CorrelationID: $correlation_id" \
    -H "Content-Type: application/json" \
    -H "Accept: */*" \
    -d "$json_payload")

# Parse response
http_body=$(echo "$response" | sed '$d')
http_code=$(echo "$response" | tail -n1)

# Check status and print result
if [[ "$http_code" == "200" ]]; then
    echo -e "✅ ${GREEN}Transfer successful (HTTP $http_code)${RESET}"
    echo -e "${GREEN}Response:${RESET} $http_body"
    echo ""
    echo -e "${GREEN}=== Payment Completed ===${RESET}"
    echo -e "${GREEN}✓ \$${amount} USD transferred from $payer_name to $payee_name${RESET}"
else
    echo -e "❌ ${RED}Transfer failed (HTTP $http_code)${RESET}"
    echo -e "${RED}Response:${RESET} $http_body"
    echo -e "${RED}Note: for payments to be processed successfully Mifos Gazelle needs to be fully deployed and running${RESET}"
    echo -e "${RED}and the hosts added to your hosts file as documented in the MIFOS-GAZELLE-README.md under docs directory${RESET}"
    exit 1
fi