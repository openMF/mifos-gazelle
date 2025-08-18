#!/usr/bin/env bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RESET='\033[0m'

# API Configuration
TRANSFER_URL="https://channel.mifos.gazelle.test/channel/transfer"
MIFOS_CORE_API="http://mifos.mifos.gazelle.test/fineract-provider/api/v1"
MIFOS_AUTH="mifos:password"

function usage() {
cat <<EOF
Usage: $0 [-p <payer_msisdn>] [-r <payee_msisdn>] [-t <tenant_id>] [-d <payee_dfsp_id>] [-v]
 -p Payer MSISDN (default: 0413356886) [optional]
 -r Payee MSISDN (default: 0495822412) [optional]
 -t Platform-TenantId (default: greenbank) [optional]
 -d X-PayeeDFSP-ID (default: bluebank) [optional]
 -v Enable debug/verbose mode [optional]
 -h Show this help message
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
    
    # Parse JSON to extract display name - try multiple approaches
    local display_name
    
    # Method 1: Look for displayName in pageItems array
    display_name=$(echo "$response" | grep -o '"displayName":"[^"]*"' | head -n1 | sed 's/"displayName":"\([^"]*\)"/\1/')
    
    # Method 2: If that fails, try looking for firstname and lastname
    if [[ -z "$display_name" ]]; then
        local firstname lastname
        firstname=$(echo "$response" | grep -o '"firstname":"[^"]*"' | head -n1 | sed 's/"firstname":"\([^"]*\)"/\1/')
        lastname=$(echo "$response" | grep -o '"lastname":"[^"]*"' | head -n1 | sed 's/"lastname":"\([^"]*\)"/\1/')
        if [[ -n "$firstname" ]] && [[ -n "$lastname" ]]; then
            display_name="$firstname $lastname"
        elif [[ -n "$firstname" ]]; then
            display_name="$firstname"
        fi
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

# Defaults
payer_msisdn="0413356886"
payee_msisdn="0495822412"
tenant_id="greenbank"
payee_dfsp_id="bluebank"
debug=false

# Parse options
while getopts ":p:r:t:d:vh" opt; do
    case $opt in
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

# Lookup client names
echo -e "${BLUE}=== Client Lookup ===${RESET}"
payer_name=$(lookup_client_name "$payer_msisdn" "$tenant_id" "payer")

# For payee, we need to determine the correct tenant
# If payee_dfsp_id is different from tenant_id, use payee_dfsp_id as tenant
payee_tenant="$tenant_id"
if [[ "$payee_dfsp_id" != "$tenant_id" ]]; then
    payee_tenant="$payee_dfsp_id"
fi

payee_name=$(lookup_client_name "$payee_msisdn" "$payee_tenant" "payee")

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