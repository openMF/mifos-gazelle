#!/usr/bin/env bash
set -euo pipefail

# demo-credit-bureau.sh — end-to-end demo of the Mifos X Credit Bureau module.
# Registers a bureau, fetches a real MifosX client via the plugin, and pulls a
# (mock) credit report — no external credentials required (CDC_MOCK_ENABLED=true).
#
# The Credit Bureau service is ClusterIP-only, so we reach it with kubectl
# port-forward rather than an ingress FQDN.

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[0;33m'; RESET='\033[0m'

NAMESPACE="mifosx"
CB_SERVICE="credit-bureau"
CB_PORT=8081
LOCAL_PORT=18081
CLIENT_ID=1          # greenbank's first demo client (Sebastian Moore)

usage() {
cat <<EOF
Usage: $0 [-i <client_id>] [-n <namespace>] [-h]
 -i  Fineract client id to pull a report for (default: $CLIENT_ID)
 -n  Kubernetes namespace (default: $NAMESPACE)
 -h  Show this help

Requires: kubectl (with a working context) and jq.
The Credit Bureau deployment must be running with CDC_MOCK_ENABLED=true and
FINERACT_TENANT_IDENTIFIER pointed at a tenant that has the client (e.g. greenbank).
EOF
}

while getopts "i:n:h" opt; do
  case "$opt" in
    i) CLIENT_ID="$OPTARG" ;;
    n) NAMESPACE="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

for tool in kubectl jq curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo -e "${RED}Error: '$tool' is required.${RESET}"; exit 1; }
done

# --- Start port-forward to the ClusterIP service --------------------------------
echo -e "${BLUE}Connecting to $CB_SERVICE in namespace $NAMESPACE ...${RESET}"
kubectl port-forward -n "$NAMESPACE" "svc/$CB_SERVICE" "$LOCAL_PORT:$CB_PORT" >/dev/null 2>&1 &
PF_PID=$!
cleanup() { kill "$PF_PID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

BASE="http://localhost:$LOCAL_PORT"
ready=false
for _ in $(seq 1 15); do
  if curl -sf "$BASE/credit-bureaus" >/dev/null 2>&1; then ready=true; break; fi
  sleep 1
done
$ready || { echo -e "${RED}Could not reach Credit Bureau at $BASE (is the pod Running?)${RESET}"; exit 1; }

# --- 1. Service reachable ------------------------------------------------------
echo -e "\n${GREEN}1.${RESET} Credit Bureau service is up. Registered bureaus:"
curl -s "$BASE/credit-bureaus" | jq .

# --- 2. Register a demo credit bureau ------------------------------------------
echo -e "\n${GREEN}2.${RESET} Registering a demo credit bureau ..."
REG=$(curl -s -X POST "$BASE/credit-bureaus" \
  -H "Content-Type: application/json" \
  -d '{"creditBureauName":"Circulo de Credito (demo)","active":true,"country":"MX","registrationParamKeys":["apiKey"]}')
BUREAU_ID=$(echo "$REG" | jq -r '.id')
echo -e "   registered bureau id=${YELLOW}${BUREAU_ID}${RESET}"

# --- 3. Fetch the client from Fineract via the plugin --------------------------
echo -e "\n${GREEN}3.${RESET} Fetching client ${YELLOW}${CLIENT_ID}${RESET} from Fineract (via the plugin) ..."
CLIENT=$(curl -s "$BASE/client/$CLIENT_ID")
if echo "$CLIENT" | jq -e '.firstName' >/dev/null 2>&1; then
  echo -e "   client: ${YELLOW}$(echo "$CLIENT" | jq -r '.firstName + " " + .lastName')${RESET}"
else
  echo -e "${RED}   Could not fetch client $CLIENT_ID — check FINERACT_TENANT_IDENTIFIER has this client.${RESET}"
fi

# --- 4. Pull a (mock) credit report --------------------------------------------
echo -e "\n${GREEN}4.${RESET} Pulling a (mock) credit report ..."
REPORT=$(curl -s -X POST "$BASE/circulo-de-credito/rcc/$CLIENT_ID?creditBureauId=$BUREAU_ID")

echo -e "\n${BLUE}=== Credit report summary ===${RESET}"
echo "$REPORT" | jq '{
  client:   ((.person.firstName // "?") + " " + (.person.lastName // "?")),
  bureau:   .bureauName,
  reportId: .reportId,
  reportDate: .reportDate,
  score:    (.scores[0].scoreValue),
  risk:     (.scores[0].riskLevel),
  sampleAccount: (.creditAccounts[0] | {creditor: .creditorName, type: .accountType, balance: .currentBalance, currency: .currency})
}'

echo -e "\n${GREEN}Done.${RESET} (Mock mode — no real Círculo de Crédito call was made.)"
