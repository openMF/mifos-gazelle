#!/usr/bin/env bash
# demo-message-gateway.sh -- end-to-end demo / smoke test of the MifosX SMS &
# Messaging module (openMF/message-gateway), using its built-in Dummy provider.
#
# Flow: register a demo tenant -> create a Dummy SMS bridge -> send a message
# -> poll its delivery status -> expect DELIVERED. No real SMS leaves the
# cluster: the Dummy provider sets the status from the message text (a body
# containing "DELIVERED" is marked delivered).
#
# Usage:   src/utils/demo-message-gateway.sh
# Needs:   kubectl access to a cluster with MifosX deployed, curl, python3.
set -euo pipefail

NS="${MIFOSX_NAMESPACE:-mifosx}"
SVC="message-gateway"
REMOTE_PORT=9191
LOCAL_PORT="${LOCAL_PORT:-19191}"
TENANT="${SMS_DEMO_TENANT:-smsdemo-$(date +%s)}"
BASE="http://localhost:${LOCAL_PORT}"
H_TID="Fineract-Platform-TenantId"
H_KEY="Fineract-Tenant-App-Key"
PF_LOG="/tmp/demo-message-gateway-pf.log"
INFRA_NS="${INFRA_NAMESPACE:-infra}"
PGPASS="${PGPASSWORD:-postgrespw}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m%s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

for c in kubectl curl python3; do command -v "$c" >/dev/null || fail "$c not found on PATH"; done

# Preflight: the module must actually be deployed, otherwise the port-forward
# has nothing to bind to and every request would fail with a refused connection.
kubectl get ns "$NS" >/dev/null 2>&1 \
  || fail "namespace '$NS' not found — is MifosX deployed? Run: ./run.sh -m deploy -a mifosx"
kubectl -n "$NS" get svc "$SVC" >/dev/null 2>&1 \
  || fail "service '$SVC' not found in '$NS' — is the SMS module deployed? Run: ./run.sh -m deploy -a mifosx"
kubectl -n "$INFRA_NS" get pod postgres-0 >/dev/null 2>&1 \
  || fail "pod 'postgres-0' not found in '$INFRA_NS' — is the infra stack deployed?"

log "Port-forwarding svc/${SVC} ${LOCAL_PORT}->${REMOTE_PORT} (namespace ${NS})"
kubectl -n "$NS" port-forward "svc/${SVC}" "${LOCAL_PORT}:${REMOTE_PORT}" >"$PF_LOG" 2>&1 &
PF=$!
trap 'kill "$PF" 2>/dev/null || true' EXIT

log "Waiting for the gateway to answer on localhost:${LOCAL_PORT}"
up=false
for _ in $(seq 1 30); do
  if curl -s -o /dev/null --max-time 5 "${BASE}/actuator/health"; then up=true; break; fi
  kill -0 "$PF" 2>/dev/null || fail "port-forward exited early — see ${PF_LOG}"
  sleep 2
done
[ "$up" = true ] || fail "could not reach ${SVC} on localhost:${LOCAL_PORT} after ~60s (see ${PF_LOG}); is the pod Ready? kubectl -n ${NS} get pods"

log "Registering demo tenant '${TENANT}' (returns a generated app key)"
APPKEY=$(curl -s -X POST "${BASE}/tenants" -H "Content-Type: application/json" \
  -d "{\"tenantId\":\"${TENANT}\",\"description\":\"Gazelle SMS demo tenant\"}" || true)
APPKEY="${APPKEY//\"/}"
[ -n "$APPKEY" ] || fail "tenant registration returned no app key (empty response)"
echo "    app key: ${APPKEY}"

log "Creating a Dummy SMS bridge for '${TENANT}' (returns the bridge id)"
BRIDGE_ID=$(curl -s -X POST "${BASE}/smsbridges" \
  -H "Content-Type: application/json" -H "${H_TID}: ${TENANT}" -H "${H_KEY}: ${APPKEY}" \
  -d '{"phoneNo":"+10000000000","providerName":"Dummy","providerKey":"Dummy","countryCode":"1","providerDescription":"Dummy demo provider"}' || true)
BRIDGE_ID="$(printf '%s' "$BRIDGE_ID" | tr -d '[:space:]')"
echo "    bridgeId: ${BRIDGE_ID:-<empty>}"
case "$BRIDGE_ID" in ''|*[!0-9]*) fail "bridge creation failed (response: ${BRIDGE_ID:-<empty>})" ;; esac

IID="$(date +%s)"
log "Sending an SMS (internalId=${IID}) via bridge ${BRIDGE_ID}; the body contains 'DELIVERED'"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${BASE}/sms" \
  -H "Content-Type: application/json" -H "${H_TID}: ${TENANT}" -H "${H_KEY}: ${APPKEY}" \
  -d "[{\"internalId\":${IID},\"mobileNumber\":\"+10000000001\",\"message\":\"Gazelle SMS demo — DELIVERED\",\"bridgeId\":${BRIDGE_ID}}]" || true)
echo "    HTTP ${code}"
case "$code" in 20*) ;; *) fail "send failed (HTTP ${code})" ;; esac

log "Checking delivery status (delivery_status 300 = DELIVERED)"
for _ in $(seq 1 15); do
  ST=$(kubectl -n "$INFRA_NS" exec postgres-0 -- env PGPASSWORD="$PGPASS" \
    psql -U postgres -d messagegateway -tAc \
    "SELECT delivery_status FROM m_outbound_messages WHERE internal_id='${IID}';" 2>/dev/null | tr -d '[:space:]' || true)
  echo "    delivery_status=${ST:-<pending>}"
  [ "$ST" = "300" ] && { ok "SMS DELIVERED — the SMS module works end-to-end (Fineract-style send -> Dummy provider -> DELIVERED)."; exit 0; }
  sleep 2
done
fail "message was not DELIVERED within the timeout"
