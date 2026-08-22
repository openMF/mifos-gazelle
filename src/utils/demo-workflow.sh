#!/usr/bin/env bash
set -euo pipefail

# demo-workflow.sh — end-to-end demo of the Mifos X Workflow Engine (Flowable).
# Runs a full client-onboarding BPMN process against Fineract: creates an inactive
# client, completes the human "verify" task (approve), assigns a loan officer and
# activates the client — then confirms the client is ACTIVE in Fineract.
#
# The Workflow Engine also exposes an ingress (workflow.<GAZELLE_DOMAIN>), but this
# script reaches both it and Fineract via kubectl port-forward so it works without
# any /etc/hosts / domain setup.

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[0;33m'; RESET='\033[0m'

NAMESPACE="mifosx"
WF_SERVICE="mifos-workflow";   WF_PORT=8081;  WF_LOCAL=18081
FIN_SERVICE="fineract-server"; FIN_PORT=8080; FIN_LOCAL=18080
TENANT="greenbank"
FIN_USER="mifos"; FIN_PASS="password"
OFFICE_ID=1
FIRST="WfDemo"; LAST="Client"

usage() {
cat <<EOF
Usage: $0 [-n <namespace>] [-t <tenant>] [-h]
 -n  Kubernetes namespace (default: $NAMESPACE)
 -t  Fineract tenant to onboard into (default: $TENANT)
 -h  Show this help

Requires: kubectl (with a working context), jq and curl.
Drives a complete client-onboarding workflow and leaves an ACTIVE client in the tenant.
EOF
}

while getopts "n:t:h" opt; do
  case "$opt" in
    n) NAMESPACE="$OPTARG" ;;
    t) TENANT="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

for tool in kubectl jq curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo -e "${RED}Error: '$tool' is required.${RESET}"; exit 1; }
done

# --- port-forward the workflow engine + Fineract -------------------------------
echo -e "${BLUE}Connecting to $WF_SERVICE and $FIN_SERVICE in namespace $NAMESPACE ...${RESET}"
kubectl port-forward -n "$NAMESPACE" "svc/$WF_SERVICE"  "$WF_LOCAL:$WF_PORT"   >/dev/null 2>&1 & PF_WF=$!
kubectl port-forward -n "$NAMESPACE" "svc/$FIN_SERVICE" "$FIN_LOCAL:$FIN_PORT" >/dev/null 2>&1 & PF_FIN=$!
cleanup() { kill "$PF_WF" "$PF_FIN" >/dev/null 2>&1 || true; }
trap cleanup EXIT

WF="http://localhost:$WF_LOCAL/api/v1"
FIN="http://localhost:$FIN_LOCAL/fineract-provider/api/v1"
fin() { curl -s -u "$FIN_USER:$FIN_PASS" -H "Fineract-Platform-TenantId: $TENANT" "$@"; }

ready=false
for _ in $(seq 1 20); do
  if curl -sf "http://localhost:$WF_LOCAL/actuator/health" >/dev/null 2>&1; then ready=true; break; fi
  sleep 1
done
$ready || { echo -e "${RED}Could not reach the Workflow Engine (is the pod Running?)${RESET}"; exit 1; }

# --- 1. authenticate (JSON body, establishes the Fineract session) -------------
echo -e "\n${GREEN}1.${RESET} Authenticating to the workflow engine ..."
AUTHED=$(curl -s -X POST "$WF/auth/authenticate" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$FIN_USER\",\"password\":\"$FIN_PASS\"}" | jq -r '.authenticated // false')
[ "$AUTHED" = "true" ] || { echo -e "${RED}   Authentication failed.${RESET}"; exit 1; }
echo -e "   authenticated as ${YELLOW}$FIN_USER${RESET} (tenant ${YELLOW}$TENANT${RESET})"

# --- 2. ensure a loan officer exists (assign-staff needs one) -------------------
echo -e "\n${GREEN}2.${RESET} Ensuring a loan officer exists in $TENANT ..."
STAFF_ID=$(fin "$FIN/staff" | jq -r 'if length>0 then .[0].id else empty end')
if [ -z "$STAFF_ID" ]; then
  STAFF_ID=$(fin -X POST "$FIN/staff" -H 'Content-Type: application/json' \
    -d "{\"officeId\":$OFFICE_ID,\"firstname\":\"Demo\",\"lastname\":\"Officer\",\"isLoanOfficer\":true,\"isActive\":true,\"joiningDate\":\"01 January 2020\",\"dateFormat\":\"dd MMMM yyyy\",\"locale\":\"en\"}" \
    | jq -r '.resourceId')
  echo -e "   created loan officer staffId=${YELLOW}${STAFF_ID}${RESET}"
else
  echo -e "   using existing staffId=${YELLOW}${STAFF_ID}${RESET}"
fi

# --- 3. start the client-onboarding workflow -----------------------------------
echo -e "\n${GREEN}3.${RESET} Starting client-onboarding for ${YELLOW}$FIRST $LAST${RESET} ..."
PROC=$(curl -s -X POST "$WF/workflow/client-onboarding/start" -H 'Content-Type: application/json' \
  -d "{\"firstName\":\"$FIRST\",\"lastName\":\"$LAST\",\"officeId\":$OFFICE_ID,\"legalFormId\":1,\"active\":false,\"locale\":\"en\",\"dateFormat\":\"dd MMMM yyyy\"}" \
  | jq -r '.id')
[ -n "$PROC" ] && [ "$PROC" != "null" ] || { echo -e "${RED}   Failed to start process.${RESET}"; exit 1; }
CLIENT_ID=$(curl -s "$WF/workflow/client-onboarding/processes/$PROC/variables" | jq -r '.clientId')
TASK_ID=$(curl -s "$WF/workflow/client-onboarding/processes/$PROC/tasks" | jq -r '.[0].taskId')
STATUS=$(fin "$FIN/clients/$CLIENT_ID" | jq -r '.status.value')
echo -e "   process ${YELLOW}${PROC:0:8}${RESET} created client ${YELLOW}$CLIENT_ID${RESET} (status: ${YELLOW}$STATUS${RESET}), awaiting verification task ${YELLOW}${TASK_ID:0:8}${RESET}"

# --- 4. complete the verify task: approve -> assign staff -> activate -----------
echo -e "\n${GREEN}4.${RESET} Approving the client (verify -> assign staff -> activate) ..."
RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$WF/workflow/client-onboarding/tasks/$TASK_ID/complete" \
  -H 'Content-Type: application/json' \
  -d "{\"approved\":true,\"clientId\":$CLIENT_ID,\"staffId\":$STAFF_ID}")
[ "$RESP" = "200" ] || { echo -e "${RED}   Task completion failed (HTTP $RESP).${RESET}"; exit 1; }
echo -e "   verification task completed"

# --- 5. confirm the client is now ACTIVE in Fineract ---------------------------
echo -e "\n${GREEN}5.${RESET} Confirming client status in Fineract ..."
FINAL=$(fin "$FIN/clients/$CLIENT_ID")
FSTATUS=$(echo "$FINAL" | jq -r '.status.value')

echo -e "\n${BLUE}=== Onboarding result ===${RESET}"
echo "$FINAL" | jq '{clientId: .id, name: .displayName, status: .status.value, active: .active, staffId: .staffId, office: .officeName}'

if [ "$FSTATUS" = "Active" ]; then
  echo -e "\n${GREEN}Done.${RESET} Client ${YELLOW}$CLIENT_ID${RESET} was onboarded end-to-end by the Workflow Engine and is now ${GREEN}ACTIVE${RESET}."
else
  echo -e "\n${YELLOW}Client ended in status '$FSTATUS' (expected Active).${RESET}"; exit 1
fi
