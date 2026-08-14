#!/usr/bin/env bash
# End-to-end agri credit demo: OpenSPP2 farmer registry -> credit decision -> MifosX loan.
# Loads the farmer registry, scores each farm with OpenSPP's own scoring engine, records the
# farmer's consent to share that verdict with the lender, then opens and disburses the loan in
# MifosX and checks it landed.
# Idempotent: a re-run leaves loans that already exist alone.
# Requires the openspp and mifosx namespaces. Run from anywhere; paths resolve from this file.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
FIXTURES="$HERE/fixtures"
LOADER="$REPO/src/utils/openspp/load-openspp-agri-data.py"
CREDIT="$REPO/src/utils/openspp/openspp-agri-credit.py"
VERIFY="$REPO/src/utils/openspp/verify-loan-in-mifosx.py"
CONFIG="$REPO/config/config.ini"

PROGRAM_NAME="Agri subsidy Q3"
# Which rail opens the loan. Empty leaves the choice to the credit script. Set to workflow or
# direct to force one:  ORIGINATION=direct bash demos/openspp/run_credit_demo.sh
# WORKFLOW_URL points the workflow rail somewhere other than its Gazelle hostname, which is what
# a machine deployed without that ingress needs.
ORIGINATION="${ORIGINATION:-}"
DOMAIN="$(crudini --get "$CONFIG" general GAZELLE_DOMAIN 2>/dev/null || echo mifos.gazelle.test)"

log() { echo -e "\n\033[1;34m==> $*\033[0m"; }
ok()  { echo -e "\033[1;32mOK $*\033[0m"; }
err() { echo -e "\033[1;31mFAIL $*\033[0m"; }

PF_PID=""
OPENSPP_URL=""
cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT

check_namespaces() {
    log "Check namespaces"
    for ns in openspp mifosx; do
        if kubectl get ns "$ns" >/dev/null 2>&1; then
            echo "  ns/$ns present"
        else
            err "namespace $ns missing"
            exit 1
        fi
    done
}

# OpenSPP is reached over a port-forward, with the local port left to kubectl: a fixed one can
# already be taken, and if what holds it is another forward the demo would talk to a different
# OpenSPP without saying so.
open_openspp_portforward() {
    log "Port-forward to OpenSPP (svc/openspp-odoo 8069)"
    kubectl port-forward -n openspp svc/openspp-odoo :8069 >/tmp/openspp-credit-pf.log 2>&1 &
    PF_PID=$!
    local port="" i
    for i in $(seq 10); do
        sleep 1
        port=$(sed -n 's/.*127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' /tmp/openspp-credit-pf.log | head -1)
        [ -n "$port" ] && break
    done
    if [ -z "$port" ]; then
        err "port-forward did not start (see /tmp/openspp-credit-pf.log)"
        exit 1
    fi
    OPENSPP_URL="http://localhost:$port"
    echo "  forwarding on $OPENSPP_URL"

    local code=000
    for i in $(seq 12); do
        sleep 5
        code=$(curl -s -o /dev/null -w '%{http_code}' "$OPENSPP_URL/web/health") || code=000
        [ "$code" = "200" ] && break
    done
    echo "  openspp health=$code"
    if [ "$code" != "200" ]; then
        err "OpenSPP did not answer on $OPENSPP_URL after a minute"
        exit 1
    fi
}

load_registry() {
    log "Load the farmer registry into OpenSPP2 (farms, land and crops)"
    python3 "$LOADER" --url "$OPENSPP_URL" --fixtures "$FIXTURES"
}

# Scores, records consent and opens the loans. Returns its last stdout line, which carries how
# many loans were opened and which tenant lent them.
decide_and_lend() {
    local options=()
    [[ -n "$ORIGINATION" ]] && options+=(--origination "$ORIGINATION")
    [[ -n "${WORKFLOW_URL:-}" ]] && options+=(--workflow-url "$WORKFLOW_URL")
    python3 "$CREDIT" --openspp-url "$OPENSPP_URL" --config "$CONFIG" \
        --program-name "$PROGRAM_NAME" "${options[@]}" | tail -1
}

main() {
    check_namespaces
    open_openspp_portforward
    load_registry

    log "Decide the credit from the registry and open the loans"
    # Which bank lent is read back and not guessed: with the rail left on auto, the script is
    # the only one that knows which one it ended up using.
    local outcome opened tenant
    outcome="$(decide_and_lend)"
    opened="${outcome%% *}"
    tenant="${outcome##* }"
    echo "  loans opened this run=$opened"

    log "Verify the loans in MifosX ($tenant)"
    local result=0
    python3 "$VERIFY" "$DOMAIN" "$FIXTURES/beneficiaries.csv" "$tenant" || result=1

    if [ "$result" -eq 0 ]; then
        ok "Agri credit demo PASSED - $opened loans opened this run"
    else
        err "Agri credit demo FAILED - $opened loans opened this run"
    fi
    return "$result"
}

main "$@"
