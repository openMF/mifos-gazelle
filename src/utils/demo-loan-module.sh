#!/usr/bin/env bash
# demo-loan-module.sh -- end-to-end demo / smoke test of the Loan Assessment
# module (openMF/reactive-loan-module).
#
# The module is event-driven: it does not accept requests directly. You create
# loan activity in Fineract, Fineract publishes a LoanCreatedBusinessEvent to
# Kafka, the module consumes it and records a risk-assessment row in its own
# loanrisk database. This script drives that flow: it creates a loan product, a
# client and a loan in Fineract (on the 'default' tenant, whose events are
# enabled), then waits for the module's assessment row to appear.
#
# Fineract publishes external events on a poll, so allow up to a couple of
# minutes. Scoring providers are stubbed upstream, so the record lands with
# PENDING statuses -- that still proves the full Fineract -> Kafka -> module ->
# loanrisk pipeline works.
#
# Usage: src/utils/demo-loan-module.sh
# Needs: kubectl access to a cluster with MifosX deployed, curl, python3.
set -euo pipefail

MIFOSX_NS="${MIFOSX_NAMESPACE:-mifosx}"
INFRA_NS="${INFRA_NAMESPACE:-infra}"
TENANT="${LOAN_DEMO_TENANT:-default}"          # events are enabled on this tenant
FIN_LOCAL="${FIN_LOCAL_PORT:-18080}"
FIN="http://localhost:${FIN_LOCAL}/fineract-provider/api/v1"
AUTH="Authorization: Basic $(printf '%s' "${FINERACT_USER:-mifos}:${FINERACT_PASSWORD:-password}" | base64)"
TID="Fineract-Platform-TenantId: ${TENANT}"
CT="Content-Type: application/json"
PGPASS="${PGPASSWORD:-postgrespw}"
PF_LOG="/tmp/demo-loan-module-pf.log"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m%s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

for c in kubectl curl python3; do command -v "$c" >/dev/null || fail "$c not found on PATH"; done

# Preflight: the module (and the infra it reads back) must be deployed.
kubectl get ns "$MIFOSX_NS" >/dev/null 2>&1 \
  || fail "namespace '$MIFOSX_NS' not found — is MifosX deployed? Run: ./run.sh -m deploy -a mifosx"
kubectl -n "$MIFOSX_NS" get svc fineract-server >/dev/null 2>&1 \
  || fail "service 'fineract-server' not found in '$MIFOSX_NS' — is MifosX deployed? Run: ./run.sh -m deploy -a mifosx"
kubectl -n "$MIFOSX_NS" get svc loan-module >/dev/null 2>&1 \
  || fail "service 'loan-module' not found in '$MIFOSX_NS' — is the Loan Assessment module deployed? Run: ./run.sh -m deploy -a mifosx"
kubectl -n "$INFRA_NS" get pod postgres-0 >/dev/null 2>&1 \
  || fail "pod 'postgres-0' not found in '$INFRA_NS' — is the infra stack deployed?"

log "Port-forwarding svc/fineract-server ${FIN_LOCAL}->8080 (namespace ${MIFOSX_NS})"
kubectl -n "$MIFOSX_NS" port-forward svc/fineract-server "${FIN_LOCAL}:8080" >"$PF_LOG" 2>&1 &
PF=$!
trap 'kill "$PF" 2>/dev/null || true' EXIT

log "Waiting for Fineract to answer on localhost:${FIN_LOCAL} (tenant ${TENANT})"
up=false
for _ in $(seq 1 60); do
  if curl -s -o /dev/null --max-time 5 -H "$AUTH" -H "$TID" "${FIN}/clients"; then up=true; break; fi
  kill -0 "$PF" 2>/dev/null || fail "port-forward exited early — see ${PF_LOG}"
  sleep 2
done
[ "$up" = true ] || fail "could not reach Fineract on localhost:${FIN_LOCAL} (see ${PF_LOG}); is fineract-server Ready? kubectl -n ${MIFOSX_NS} get pods"

# POST helper: returns the resourceId, or fails loudly printing the raw response.
post_rid() {
  local path="$1" body="$2" resp rid
  resp=$(curl -s -X POST "${FIN}${path}" -H "$AUTH" -H "$TID" -H "$CT" -d "$body" || true)
  rid=$(printf '%s' "$resp" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("resourceId",""))
except Exception: pass' 2>/dev/null || true)
  [ -n "$rid" ] || { printf '    response: %s\n' "$resp" >&2; return 1; }
  printf '%s' "$rid"
}

TODAY="$(date +'%d %B %Y')"
SHORT="D$(printf '%03d' $((RANDOM % 1000)))"   # unique-ish, <=4 chars

log "Creating a loan product (${SHORT})"
PID=$(post_rid /loanproducts "{
  \"name\":\"Loan Demo ${SHORT}\",\"shortName\":\"${SHORT}\",\"currencyCode\":\"USD\",
  \"digitsAfterDecimal\":2,\"inMultiplesOf\":0,\"principal\":10000,\"minPrincipal\":1000,\"maxPrincipal\":100000,
  \"numberOfRepayments\":12,\"repaymentEvery\":1,\"repaymentFrequencyType\":2,
  \"interestRatePerPeriod\":2,\"interestRateFrequencyType\":2,\"amortizationType\":1,\"interestType\":0,
  \"interestCalculationPeriodType\":1,\"transactionProcessingStrategyCode\":\"mifos-standard-strategy\",
  \"daysInYearType\":365,\"daysInMonthType\":30,\"isInterestRecalculationEnabled\":false,
  \"accountingRule\":1,\"locale\":\"en\",\"dateFormat\":\"dd MMMM yyyy\"}") || fail "loan product creation failed (response above)"
echo "    productId=${PID}"

log "Creating a client"
CID=$(post_rid /clients "{
  \"officeId\":1,\"firstname\":\"Loan\",\"lastname\":\"Demo\",\"legalFormId\":1,
  \"active\":true,\"activationDate\":\"${TODAY}\",\"locale\":\"en\",\"dateFormat\":\"dd MMMM yyyy\"}") || fail "client creation failed (response above)"
echo "    clientId=${CID}"

log "Submitting a loan application"
LID=$(post_rid /loans "{
  \"clientId\":${CID},\"productId\":${PID},\"principal\":10000,
  \"loanTermFrequency\":12,\"loanTermFrequencyType\":2,\"numberOfRepayments\":12,
  \"repaymentEvery\":1,\"repaymentFrequencyType\":2,\"interestRatePerPeriod\":2,
  \"amortizationType\":1,\"interestType\":0,\"interestCalculationPeriodType\":1,
  \"transactionProcessingStrategyCode\":\"mifos-standard-strategy\",
  \"expectedDisbursementDate\":\"${TODAY}\",\"submittedOnDate\":\"${TODAY}\",
  \"loanType\":\"individual\",\"locale\":\"en\",\"dateFormat\":\"dd MMMM yyyy\"}") || fail "loan submission failed (response above)"
echo "    loanId=${LID}"

log "Waiting for the module to record an assessment for loan ${LID} (Fineract publishes on a poll; up to ~3 min)"
psql_loanrisk() {
  kubectl -n "$INFRA_NS" exec postgres-0 -- env PGPASSWORD="$PGPASS" \
    psql -U postgres -d loanrisk -tAc "$1" 2>/dev/null || true
}
for _ in $(seq 1 30); do
  ROW=$(psql_loanrisk "SELECT loan_id||' | '||loan_status||' | '||assessment_status FROM aggregator WHERE loan_id=${LID};")
  if [ -n "$ROW" ]; then
    ok "Assessment recorded (loan_id | loan_status | assessment_status): ${ROW}"
    ok "Loan Assessment module works end-to-end (Fineract -> Kafka -> module -> loanrisk)."
    exit 0
  fi
  sleep 6
done
fail "no assessment recorded for loan ${LID} within the timeout (check: kubectl -n ${MIFOSX_NS} logs deploy/loan-module)"
