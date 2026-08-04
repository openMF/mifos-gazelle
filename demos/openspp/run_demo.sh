#!/usr/bin/env bash
# End-to-end agri demo: OpenSPP2 -> PHEE -> MifosX.
# Loads agri data into OpenSPP2, pays each approved entitlement through Payment Hub's
# channel/transfer and checks the subsidy landed in the beneficiary's MifosX (bluebank)
# savings account.
# Idempotent: a re-run only pays entitlements that are still approved.
# Requires the full stack up: openspp, paymenthub, mifosx and vnext namespaces.
# Run from anywhere; paths resolve relative to this file.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
FIXTURES="$HERE/fixtures"
LOADER="$REPO/src/utils/openspp/load-openspp-agri-data.py"
BRIDGE="$REPO/src/utils/openspp/openspp-agri-demo.py"
VERIFY="$REPO/src/utils/openspp/verify-credit-in-mifosx.py"
CONFIG="$REPO/config/config.ini"

PAYEE_TENANT="bluebank"
PROGRAM_NAME="Agri subsidy Q3"
DOMAIN="$(crudini --get "$CONFIG" general GAZELLE_DOMAIN 2>/dev/null || echo mifos.gazelle.test)"

log() { echo -e "\n\033[1;34m==> $*\033[0m"; }
ok()  { echo -e "\033[1;32mOK $*\033[0m"; }
err() { echo -e "\033[1;31mFAIL $*\033[0m"; }

PF_PID=""
OPENSPP_URL=""          # set by open_openspp_portforward
cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT

check_namespaces() {
    log "Check namespaces"
    for ns in openspp paymenthub mifosx vnext; do
        if kubectl get ns "$ns" >/dev/null 2>&1; then
            echo "  ns/$ns present"
        else
            err "namespace $ns missing"
            exit 1
        fi
    done
}

# OpenSPP is reached over a port-forward, the same way the deployer verifies it and the
# data loader documents. The local port is left to kubectl: a fixed one can already be
# taken, and if what holds it is another forward the demo would talk to a different
# OpenSPP without saying so.
open_openspp_portforward() {
    log "Port-forward to OpenSPP (svc/openspp-odoo 8069)"
    kubectl port-forward -n openspp svc/openspp-odoo :8069 >/tmp/openspp-pf.log 2>&1 &
    PF_PID=$!
    local port="" i
    for i in $(seq 10); do
        sleep 1
        port=$(sed -n 's/.*127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' /tmp/openspp-pf.log | head -1)
        [ -n "$port" ] && break
    done
    if [ -z "$port" ]; then
        err "port-forward did not start (see /tmp/openspp-pf.log)"
        exit 1
    fi
    OPENSPP_URL="http://localhost:$port"
    echo "  forwarding on $OPENSPP_URL"

    # Odoo can take about a minute to start serving after a fresh deploy.
    local code=000
    for i in $(seq 12); do
        sleep 5
        code=$(curl -s -o /dev/null -w '%{http_code}' "$OPENSPP_URL/web/health") || code=000
        [ "$code" = "200" ] && break
    done
    echo "  openspp health=$code"
    if [ "$code" != "200" ]; then
        err "OpenSPP did not answer on $OPENSPP_URL after a minute (see /tmp/openspp-pf.log)"
        exit 1
    fi
}

load_agri_data() {
    log "Load agri data into OpenSPP2 (installs the farmer registry if missing)"
    python3 "$LOADER" --url "$OPENSPP_URL" --fixtures "$FIXTURES"
}

# The logic lives in oracle-upsert.js; here only the data. The MSISDN list travels in an
# environment variable because kubectl exec does not carry the local ones into the
# container.
register_payees_in_oracle() {
    log "Register payees in the vNext ALS built-in oracle (Mongo)"
    local mongo_uri payees out
    mongo_uri="mongodb://root:mongoDbPas42@localhost:27017/account-lookup?authSource=admin"

    # The msisdn column of the fixture, found by name so the column order can change.
    payees=$(awk -F, 'NR==1 {for (i = 1; i <= NF; i++) if ($i == "msisdn") col = i; next}
                      col && $col ~ /^[0-9]+$/ {print $col}' \
                      "$FIXTURES/beneficiaries.csv" | tr '\n' ' ')
    if [ -z "$payees" ]; then
        err "no MSISDN found in $FIXTURES/beneficiaries.csv"
        exit 1
    fi

    if ! out=$(kubectl exec -i -n infra mongodb-0 -c mongodb -- \
        env PAYEES="$payees" FSP_ID="$PAYEE_TENANT" \
        mongosh "$mongo_uri" --quiet < "$HERE/oracle-upsert.js" 2>&1); then
        echo "$out"
        err "mongo upsert failed (check mongodb-0 / creds)"
        exit 1
    fi
    echo "$out" | grep -vE "Warning|deprecat" || true
}

# Pays each approved entitlement through Payment Hub and prints the number of subsidies
# paid on its last stdout line, which is what this function returns.
bridge_to_phee() {
    python3 "$BRIDGE" --openspp-url "$OPENSPP_URL" --config "$CONFIG" \
        --program-name "$PROGRAM_NAME" --payee-tenant "$PAYEE_TENANT" | tail -1
}

# Check each beneficiary got a deposit matching their subsidy amount in bluebank.
# When this run paid, ask about THIS run: with a time the verifier reads Fineract's audit,
# the only place that keeps a clock, so the subsidies of an earlier run on the same day are
# not mistaken for this one's. When it paid nothing, everything was already paid, so the
# question is the other one, "is every beneficiary credited", and the day window answers it.
verify_credit_in_mifosx() {
    local paid_count="$1"
    if [ "$paid_count" -gt 0 ] 2>/dev/null; then
        python3 "$VERIFY" "$DOMAIN" "$FIXTURES/beneficiaries.csv" "$PAYEE_TENANT" \
            --since "$STARTED_AT"
    else
        python3 "$VERIFY" "$DOMAIN" "$FIXTURES/beneficiaries.csv" "$PAYEE_TENANT"
    fi
}

main() {
    # In UTC because that is how Fineract reads the audit filter, and a minute early to
    # absorb any clock difference with the cluster. Python and not date(1): the GNU and
    # BSD versions disagree on how to subtract a minute, and python3 is already needed.
    STARTED_AT="$(python3 -c "import datetime as d; print((d.datetime.now(d.timezone.utc) - d.timedelta(minutes=1)).strftime('%Y-%m-%d %H:%M:%S'))")"
    echo "  run started at $STARTED_AT UTC"

    check_namespaces
    open_openspp_portforward
    load_agri_data
    register_payees_in_oracle

    log "Pay approved entitlements via PHEE channel/transfer, one at a time"
    local paid_count
    paid_count="$(bridge_to_phee)"
    echo "  subsidies paid=$paid_count"

    log "Verify subsidy credited in MifosX ($PAYEE_TENANT)"
    sleep 5   # the bridge already confirmed each credit; small settle margin
    local result=0
    verify_credit_in_mifosx "$paid_count" || result=1

    if [ "$result" -eq 0 ]; then
        ok "E2E demo PASSED - $paid_count subsidies paid this run"
    else
        err "E2E demo FAILED - $paid_count subsidies paid this run"
    fi
    return "$result"
}

main "$@"
