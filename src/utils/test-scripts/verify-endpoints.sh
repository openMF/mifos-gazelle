#!/usr/bin/env bash
# Verifies all Gazelle ingress endpoints are reachable.
# Exits non-zero if any critical endpoint is down — use as a CI gate before
# running make-payment.sh or cucumber tests.
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
RESET='\033[0m'

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONFIG_INI="${CONFIG_INI:-$SCRIPT_DIR/../../../config/config.ini}"

if [[ ! -f "$CONFIG_INI" ]]; then
    echo -e "${RED}Error: config.ini not found at $CONFIG_INI${RESET}" >&2
    exit 1
fi

GAZELLE_DOMAIN=$(grep 'GAZELLE_DOMAIN' "$CONFIG_INI" | cut -d'=' -f2 | tr -d ' ')
if [[ -z "$GAZELLE_DOMAIN" ]]; then
    echo -e "${RED}Error: GAZELLE_DOMAIN not set in $CONFIG_INI${RESET}" >&2
    exit 1
fi

TIMEOUT=10   # seconds per request
PASS=0
FAIL=0
WARN=0

# check_endpoint <label> <url> <critical: true|false>
# Passes if HTTP status is 1xx-4xx (service is up and routing).
# Fails on 5xx (app error) or 000 (no connection / timeout).
check_endpoint() {
    local label="$1"
    local url="$2"
    local critical="$3"

    local http_code
    # Use || true so a curl failure doesn't abort the script; %{http_code}
    # still outputs "000" on connection failure before curl exits non-zero.
    http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
        --max-time "$TIMEOUT" --connect-timeout "$TIMEOUT" \
        -L "$url" 2>/dev/null) || true

    # Strip non-digits and force base-10 to avoid octal interpretation of "000"
    local numeric
    numeric=$(( 10#${http_code//[^0-9]/0} ))

    local status="ok"
    if [[ $numeric -eq 0 ]] || [[ $numeric -ge 500 ]]; then
        status="fail"
    fi

    if [[ "$status" == "ok" ]]; then
        printf "  ${GREEN}[PASS]${RESET} %-52s HTTP %s\n" "$label" "$http_code"
        PASS=$((PASS + 1))
    elif [[ "$critical" == "true" ]]; then
        printf "  ${RED}[FAIL]${RESET} %-52s HTTP %s  ← CRITICAL\n" "$label" "$http_code"
        FAIL=$((FAIL + 1))
    else
        printf "  ${YELLOW}[WARN]${RESET} %-52s HTTP %s\n" "$label" "$http_code"
        WARN=$((WARN + 1))
    fi
}

echo ""
echo -e "${BLUE}=== Gazelle Endpoint Verification ===${RESET}"
echo -e "    Domain:  ${GAZELLE_DOMAIN}"
echo -e "    Timeout: ${TIMEOUT}s per request"
echo ""

echo -e "${BLUE}--- Critical (must pass for CI to continue) ---${RESET}"
check_endpoint "MifosX UI"                    "https://mifos.${GAZELLE_DOMAIN}"                          true
check_endpoint "vNext Admin UI"               "http://vnextadmin.${GAZELLE_DOMAIN}"                       true
check_endpoint "PHEE Operations Web"          "https://ops.${GAZELLE_DOMAIN}"                             true
check_endpoint "PHEE Channel Connector"       "https://channel.${GAZELLE_DOMAIN}"                         true
check_endpoint "PHEE Operations App (API)"    "https://ops-bk.${GAZELLE_DOMAIN}/actuator/health"          true
check_endpoint "PHEE Identity Account Mapper" "https://identity-mapper.${GAZELLE_DOMAIN}/actuator/health" true

echo ""
echo -e "${BLUE}--- Informational (reported but do not block CI) ---${RESET}"
check_endpoint "Elasticsearch"                "http://elasticsearch.${GAZELLE_DOMAIN}"                    false
check_endpoint "Kibana"                       "http://kibana.${GAZELLE_DOMAIN}"                           false
check_endpoint "Mongo Express"                "http://mongoexpress.${GAZELLE_DOMAIN}"                     false
check_endpoint "Redpanda Console"             "http://redpanda-console.${GAZELLE_DOMAIN}"                 false
check_endpoint "Minio Console"                "http://minio-console.${GAZELLE_DOMAIN}"                    false
check_endpoint "Zeebe Operate"                "http://zeebe-operate.${GAZELLE_DOMAIN}"                    false
check_endpoint "PHEE Bulk Processor"          "https://bulk-processor.${GAZELLE_DOMAIN}"                  false
check_endpoint "PHEE Connector Bulk"          "https://connector-bulk.${GAZELLE_DOMAIN}"                  false
check_endpoint "PHEE Mojaloop Connector"      "https://mojaloop.${GAZELLE_DOMAIN}"                        false
check_endpoint "PHEE AMS Mifos Connector"     "https://ams-mifos.${GAZELLE_DOMAIN}"                       false
check_endpoint "PHEE Channel GSMA"            "https://channel-gsma.${GAZELLE_DOMAIN}"                    false
check_endpoint "Minio S3 API"                 "http://minio.${GAZELLE_DOMAIN}"                            false
check_endpoint "PHEE Zeebe Ops"               "http://zeebeops.${GAZELLE_DOMAIN}"                         false
check_endpoint "vNext FSPIOP API"             "http://fspiop.${GAZELLE_DOMAIN}"                           false

echo ""
echo -e "${BLUE}=== Summary ===${RESET}"
echo -e "  ${GREEN}Passed:${RESET}   $PASS"
[[ $WARN -gt 0 ]] && echo -e "  ${YELLOW}Warnings:${RESET} $WARN (informational only)"
[[ $FAIL -gt 0 ]] && echo -e "  ${RED}Failed:${RESET}   $FAIL (critical)"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo -e "${RED}FATAL: $FAIL critical endpoint(s) unreachable.${RESET}"
    echo -e "${RED}Fix the deployment before running make-payment.sh or cucumber tests.${RESET}"
    exit 1
fi

echo -e "${GREEN}All critical endpoints reachable. Safe to proceed.${RESET}"
exit 0
