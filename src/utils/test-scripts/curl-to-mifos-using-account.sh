#!/usr/bin/env bash
# =============================================================================
# lookup-fineract-account.sh
# Lookup savings/loan account in MifosX / Fineract (Gazelle local setup)
#
# Usage:
#   ./lookup-fineract-account.sh [-t TENANT] [-a ACCOUNT_NUMBER] [-y TYPE] [-h]
#
# Options:
#   -t TENANT         Tenant name (default: bluebank)
#   -a ACCOUNT_NUMBER Account number (default: 000000001)
#   -y TYPE           Account type: savings | loans (default: savings)
#   -h                Show this help message
#
# Examples:
#   ./lookup-fineract-account.sh                     # defaults
#   ./lookup-fineract-account.sh -t redbank          # change tenant only
#   ./lookup-fineract-account.sh -t greenbank -a 00012345 -y loans
# =============================================================================

set -euo pipefail

# Configuration
BASE_URL="http://mifos.mifos.gazelle.localhost"
USERNAME="mifos"
PASSWORD="password"

# Defaults
TENANT="bluebank"
ACCOUNT_NUMBER="000000001"
ACCOUNT_TYPE="savings"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Print usage
usage() {
    echo "Usage: $0 [-t TENANT] [-a ACCOUNT_NUMBER] [-y TYPE] [-h]"
    echo ""
    echo "Options:"
    echo "  -t TENANT         Tenant name (default: bluebank)"
    echo "  -a ACCOUNT_NUMBER Account number (default: 000000001)"
    echo "  -y TYPE           Account type: savings | loans (default: savings)"
    echo "  -h                Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0"
    echo "  $0 -t redbank"
    echo "  $0 -t greenbank -a 00012345 -y loans"
    exit 1
}

# Parse options with getopts
while getopts ":t:a:y:h" opt; do
    case $opt in
        t)  TENANT="$OPTARG" ;;
        a)  ACCOUNT_NUMBER="$OPTARG" ;;
        y)  ACCOUNT_TYPE="$OPTARG" ;;
        h)  usage ;;
        \?) echo -e "${RED}Invalid option: -$OPTARG${NC}" >&2; usage ;;
        :)  echo -e "${RED}Option -$OPTARG requires an argument.${NC}" >&2; usage ;;
    esac
done

# Validate account type
if [[ "$ACCOUNT_TYPE" != "savings" && "$ACCOUNT_TYPE" != "loans" ]]; then
    echo -e "${RED}Invalid account type: '$ACCOUNT_TYPE'${NC}"
    echo "Must be: savings | loans"
    exit 1
fi

# Build endpoint
if [[ "$ACCOUNT_TYPE" == "savings" ]]; then
    ENDPOINT="/savingsaccounts/${ACCOUNT_NUMBER}"
else
    ENDPOINT="/loans/${ACCOUNT_NUMBER}"
fi

URL="${BASE_URL}/fineract-provider/api/v1${ENDPOINT}?associations=all"

# Base64 auth
AUTH_HEADER=$(echo -n "${USERNAME}:${PASSWORD}" | base64)

echo "Looking up ${ACCOUNT_TYPE} account ${ACCOUNT_NUMBER} in tenant '${TENANT}'..."
echo "URL: ${URL}"
echo ""

# Execute curl
response=$(curl -s -w "\n%{http_code}" \
    -X GET "${URL}" \
    -H "Content-Type: application/json" \
    -H "Fineract-Platform-TenantId: ${TENANT}" \
    -H "Authorization: Basic ${AUTH_HEADER}" \
    -H "Accept: application/json")

# Split body and status code
body=$(echo "$response" | sed '$d')
status=$(echo "$response" | tail -n1)

if [[ "$status" == 200 ]]; then
    echo -e "${GREEN}Success (200)${NC}"
    if command -v jq >/dev/null 2>&1; then
        echo "$body" | jq .
    else
        echo "$body"
    fi
else
    echo -e "${RED}Failed (${status})${NC}"
    if command -v jq >/dev/null 2>&1; then
        echo "$body" | jq . 2>/dev/null || echo "$body"
    else
        echo "$body"
    fi
    exit 1
fi