#!/usr/bin/env bash
# apply-crs.sh -- Re-apply PaymentHub operator CRs without a full redeploy.
#
# Use this after editing CR files (e.g. updating image tags) to push the changes
# into the running cluster. The operator performs rolling updates only for pods
# whose spec changed, so unchanged pods are not restarted.
#
# Usage:
#   src/utils/apply-crs.sh [--wait]
#
# Options:
#   --wait   Wait for all enabled CRs to reach ready state after applying (default: no wait)

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [--wait] [-h|--help]

Re-apply PaymentHub operator CRs without a full redeploy.

Use this after editing CR files (e.g. updating image tags in
src/deployer/operators/paymenthub/config/cr/) to push changes into
the running cluster. The PaymentHub operator performs rolling updates
only for pods whose spec changed — unchanged pods are not restarted.

Options:
  --wait        Poll until all enabled CRs reach ready state (up to 5 min)
  -h, --help    Show this help

Examples:
  # Apply updated CR image tags immediately:
  src/utils/apply-crs.sh

  # Apply and wait for all CRs to reconcile before returning:
  src/utils/apply-crs.sh --wait

CR files: src/deployer/operators/paymenthub/config/cr/*.yaml
Config  : config/config.ini  (GAZELLE_DOMAIN, paymenthub.namespace)

See also:
  src/utils/localdev/localdev.py --clean-backups   # remove stale localdev patch backups
  src/utils/localdev/localdev.py --status          # show which components are locally patched
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load config to get GAZELLE_DOMAIN and PH_NAMESPACE
CONFIG_FILE="${RUN_DIR}/config/config.ini"
if ! command -v crudini &>/dev/null; then
  echo "ERROR: crudini is required. Install it or activate the project venv." >&2
  exit 1
fi

GAZELLE_DOMAIN=$(crudini --get "$CONFIG_FILE" general GAZELLE_DOMAIN 2>/dev/null || echo "mifos.gazelle.test")
PH_NAMESPACE=$(crudini --get "$CONFIG_FILE" paymenthub namespace 2>/dev/null || echo "paymenthub")

WAIT=false
for arg in "$@"; do
  case "$arg" in
    --wait) WAIT=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg"; usage; exit 1 ;;
  esac
done

CR_DIR="${RUN_DIR}/src/deployer/operators/paymenthub/config/cr"

echo "Applying PaymentHub CRs → ${GAZELLE_DOMAIN} (namespace: ${PH_NAMESPACE})"

if ! kubectl get namespace "$PH_NAMESPACE" &>/dev/null; then
  echo "ERROR: Namespace '$PH_NAMESPACE' not found. Run a full deploy first." >&2
  exit 1
fi

TMP=$(mktemp /tmp/ph-crs.XXXXXX.yaml)
trap 'rm -f "$TMP"' EXIT

for f in "$CR_DIR"/*.yaml; do
  echo "---"
  sed -e "s/\\.local$/.${GAZELLE_DOMAIN}/g" \
      -e "s/GAZELLE_DOMAIN/${GAZELLE_DOMAIN}/g" \
      "$f"
done > "$TMP"

kubectl apply -f "$TMP"
echo "CRs applied."

if [[ "$WAIT" == "true" ]]; then
  echo "Waiting for all enabled CRs to reconcile..."
  TIMEOUT=300
  ELAPSED=0
  INTERVAL=10
  while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    OUTPUT=$(kubectl get paymenthubdeployments -n "$PH_NAMESPACE" \
      -o jsonpath='{range .items[?(@.spec.enabled==true)]}{.metadata.name}:{.status.ready} {end}' 2>/dev/null \
      | tr ' ' '\n' | grep -v '^$')
    TOTAL=$(echo "$OUTPUT" | grep -c '.' || true)
    RECONCILED=$(echo "$OUTPUT" | grep -c ':true\|:false' || true)
    NOT_READY=$(echo "$OUTPUT" | grep ':false' | cut -d: -f1 | tr '\n' ',' | sed 's/,$//' || true)
    echo "  CRs reconciled: ${RECONCILED}/${TOTAL} (${ELAPSED}s)${NOT_READY:+ — not ready: $NOT_READY}"
    if [ "$TOTAL" -gt 0 ] && [ "$RECONCILED" -eq "$TOTAL" ] && [ -z "$NOT_READY" ]; then
      echo "All CRs ready."
      exit 0
    fi
    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))
  done
  echo "WARNING: Timed out after ${TIMEOUT}s waiting for CRs." >&2
  exit 1
fi
