#!/usr/bin/env bash
# Minimal unit test: verifies the unanchored grep bug in
# deleteResourcesInNamespaceMatchingPattern (deployer.sh line 72).
#
# Tests pure grep logic only — no cluster, no kubectl required.

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Simulated output of: kubectl get namespaces -o name
CLUSTER_NAMESPACES="namespace/default
namespace/kube-system
namespace/infra
namespace/infra-monitoring
namespace/paymenthub
namespace/paymenthub-operator
namespace/paymenthub-staging
namespace/mifosx
namespace/mifosx-backup
namespace/vnext"

grep_buggy() {
    local pattern="$1"
    echo "$CLUSTER_NAMESPACES" | grep -E "$pattern" | sed 's/^namespace\///'
}

grep_fixed() {
    local pattern="$1"
    echo "$CLUSTER_NAMESPACES" | grep -E "^namespace/${pattern}$" | sed 's/^namespace\///'
}

echo ""
echo "=== Confirming bug: unanchored grep -E over-matches ==="
echo ""

# These document the broken behavior — they are expected to output a CONFIRMED line.
paymenthub_buggy=$(grep_buggy "paymenthub")
infra_buggy=$(grep_buggy "infra")
mifosx_buggy=$(grep_buggy "mifosx")

echo "  CONFIRMED: 'paymenthub' (buggy) would delete: $(echo "$paymenthub_buggy" | tr '\n' ' ')"
echo "  CONFIRMED: 'infra'      (buggy) would delete: $(echo "$infra_buggy" | tr '\n' ' ')"
echo "  CONFIRMED: 'mifosx'     (buggy) would delete: $(echo "$mifosx_buggy" | tr '\n' ' ')"

echo ""
echo "=== Verifying fix: anchored grep -E \"^namespace/\${pattern}\$\" ==="
echo ""

# paymenthub: must match only itself
result=$(grep_fixed "paymenthub")
echo "$result" | grep -qx "paymenthub"          && pass "paymenthub: matched intended namespace"   || fail "paymenthub: did not match intended namespace"
echo "$result" | grep -q  "paymenthub-operator" && fail "paymenthub: still matches paymenthub-operator" || pass "paymenthub: excluded paymenthub-operator"
echo "$result" | grep -q  "paymenthub-staging"  && fail "paymenthub: still matches paymenthub-staging"  || pass "paymenthub: excluded paymenthub-staging"

# infra: must match only itself
result=$(grep_fixed "infra")
echo "$result" | grep -qx "infra"               && pass "infra: matched intended namespace"        || fail "infra: did not match intended namespace"
echo "$result" | grep -q  "infra-monitoring"    && fail "infra: still matches infra-monitoring"    || pass "infra: excluded infra-monitoring"

# mifosx: must match only itself
result=$(grep_fixed "mifosx")
echo "$result" | grep -qx "mifosx"              && pass "mifosx: matched intended namespace"       || fail "mifosx: did not match intended namespace"
echo "$result" | grep -q  "mifosx-backup"       && fail "mifosx: still matches mifosx-backup"      || pass "mifosx: excluded mifosx-backup"

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""

[ $FAIL -eq 0 ] && exit 0 || exit 1
