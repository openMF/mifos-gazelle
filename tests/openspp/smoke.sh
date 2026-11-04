#!/usr/bin/env bash
# Smoke test for the OpenSPP2 deployment. Checks the pods are Ready, the base module is really
# installed (a 200 alone is not enough, another empty Odoo also returns 200), and /web/health responds.
# Usage: bash tests/openspp/smoke.sh   (override the namespace with OPENSPP_NAMESPACE).
set -euo pipefail

NS="${OPENSPP_NAMESPACE:-openspp}"
MODULE="${OPENSPP_MODULE:-spp_base_common}"
rc=0

pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; rc=1; }

echo "OpenSPP2 smoke test (namespace: $NS)"

# Pods Ready (postgis + odoo; jobworker if present).
for app in openspp-postgis openspp-odoo; do
    if kubectl get pods -n "$NS" -l "app=$app" \
        -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null | grep -q true; then
        pass "$app pod is Ready"
    else
        fail "$app pod is not Ready"
    fi
done

# Base module actually installed (query PostGIS directly).
installed=$(kubectl exec -n "$NS" statefulset/openspp-postgis -- \
    psql -U odoo -d openspp -tAc \
    "SELECT 1 FROM ir_module_module WHERE name='$MODULE' AND state='installed'" 2>/dev/null | tr -d '[:space:]')
if [ "$installed" = "1" ]; then
    pass "module $MODULE is installed"
else
    fail "module $MODULE is NOT installed (Odoo may be empty)"
fi

# /web/health returns 200 (checked from inside the odoo pod, no ingress/hosts needed).
code=$(kubectl exec -n "$NS" deploy/openspp-odoo -c odoo -- \
    curl -s -o /dev/null -w '%{http_code}' http://localhost:8069/web/health 2>/dev/null || true) # localhost of the pod, not the host
if [ "$code" = "200" ]; then
    pass "/web/health returns 200"
else
    fail "/web/health returned '$code' (expected 200)"
fi

echo
if [ "$rc" -eq 0 ]; then echo "OpenSPP2 smoke test: OK"; else echo "OpenSPP2 smoke test: FAILED"; fi
exit "$rc"
