#!/usr/bin/env bash
# openg2p-data-setup.sh -- populates the PBMS registry as a demo environment by
# mirroring the deployed MifosX/Fineract clients into it as registrants, then
# creating a demo program they can be paid through. Driven via
# `kubectl exec ... odoo shell` on the pbms-odoo pod. Safe to re-run.
#
# Clients are read live from Fineract rather than regenerated because
# generate-mifos-vnext-data.py produces different people on every run.
#
# Steps:
#   1  Fetch clients (displayName + mobileNo) from Fineract per tenant.
#   2  Create each as an individual res.partner registrant in PBMS.
#   3  Create the demo program with an age-based eligibility_domain.
#   4  Create + wire a PHEE payment manager on the program.
#   5  Fund the program (g2p.program.fund).
#   6  Register the clients in the vNext ALS oracle so party lookup resolves them.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONFIG_FILE="${RUN_DIR}/config/config.ini"

# shellcheck source=/dev/null
source "${RUN_DIR}/src/utils/logger.sh"

ODOO_DB="pbmsdb"
# ONLY bluebank: it is the sole tenant onboarded as a Payee FSP in the vNext switch
# (docs/GOVSTACK.md). redbank is not a participant, so payments to its payees fail
# party lookup; greenbank is the payer. This keeps every registrant payable.
FINERACT_TENANTS=(bluebank)
# Fineract basic-auth from config.ini [mifosx] — the same keys mifosx.sh reads.
# An exported env var of the same name wins, so run.sh overrides are inherited.
FINERACT_USERNAME="${FINERACT_USERNAME:-$(crudini --get "$CONFIG_FILE" \
  mifosx FINERACT_USERNAME 2>/dev/null || echo mifos)}"
FINERACT_PASSWORD="${FINERACT_PASSWORD:-$(crudini --get "$CONFIG_FILE" \
  mifosx FINERACT_PASSWORD 2>/dev/null || echo password)}"
# tr -d, not `base64 -w0`: -w is GNU-only and this repo also runs on macOS.
FINERACT_AUTH="Basic $(printf '%s:%s' \
  "$FINERACT_USERNAME" "$FINERACT_PASSWORD" | base64 | tr -d '\n')"

# The payer tenant (a Fineract tenant, NOT an MSISDN). Its client's MSISDN is
# resolved at runtime rather than pinned, because the demo dump's MSISDNs are
# regenerated periodically. It feeds EXCLUDE_MSISDNS and the manager's payer_id.
PHEE_PAYER_TENANT="$(crudini --get "$CONFIG_FILE" \
  openg2p OPENG2P_PHEE_PAYER_TENANT 2>/dev/null || echo greenbank)"

# Payers to exclude from the registry, by MSISDN (stable, unlike names).
# Populated in main() with the resolved PHEE_PAYER_TENANT MSISDN.
EXCLUDE_MSISDNS=()

# Demo program config, from config.ini [openg2p]. The eligibility domain selects
# registrants aged [ELIG_MIN_AGE, ELIG_MAX_AGE]; those outside are the "filtered
# out" set. The band stays in-script because it is tuned to the deterministic
# per-MSISDN ages of the seeded bluebank clients: 18-70 leaves 4 eligible and
# filters out one minor and one elder, keeping the demo batch small.
DEMO_PROGRAM_NAME="$(crudini --get "$CONFIG_FILE" \
  openg2p OPENG2P_DEMO_PROGRAM_NAME 2>/dev/null || echo "Demo Program")"
ELIG_MIN_AGE=18
ELIG_MAX_AGE=70
# Validated in main(): both are interpolated below as bare Python numeric literals.
ENTITLEMENT_AMOUNT_PER_CYCLE="$(crudini --get "$CONFIG_FILE" \
  openg2p OPENG2P_ENTITLEMENT_AMOUNT_PER_CYCLE 2>/dev/null || echo 50.0)"
PROGRAM_FUND_AMOUNT="$(crudini --get "$CONFIG_FILE" \
  openg2p OPENG2P_PROGRAM_FUND_AMOUNT 2>/dev/null || echo 1000.0)"

# PHEE payment manager config. The connector POSTs the batch CSV (multipart) with
# Platform-TenantId + Type:csv headers and does NO OAuth handshake in this version,
# so the auth/status/details URLs and authorization/grant_type are unused
# placeholders. The tenant id IS the payer tenant, so it is derived here.
PHEE_TENANT_ID="$PHEE_PAYER_TENANT"
PHEE_PAYER_ID_TYPE="$(crudini --get "$CONFIG_FILE" \
  openg2p OPENG2P_PHEE_PAYER_ID_TYPE 2>/dev/null || echo msisdn)"
PHEE_PAYEE_ID_TYPE="$(crudini --get "$CONFIG_FILE" \
  openg2p OPENG2P_PHEE_PAYEE_ID_TYPE 2>/dev/null || echo phone)"
# Empty means "resolve from Fineract in main()"; a value pins it and skips that.
PHEE_PAYER_ID="$(crudini --get "$CONFIG_FILE" \
  openg2p OPENG2P_PHEE_PAYER_ID 2>/dev/null)"
# Connector credentials. Unused by this version, but the Odoo model requires them.
PHEE_CLIENT_ID="$(crudini --get "$CONFIG_FILE" \
  openg2p OPENG2P_PHEE_CLIENT_ID 2>/dev/null || echo client)"
PHEE_CLIENT_SECRET="$(crudini --get "$CONFIG_FILE" \
  openg2p OPENG2P_PHEE_CLIENT_SECRET 2>/dev/null)"
PHEE_USERNAME="$(crudini --get "$CONFIG_FILE" \
  openg2p OPENG2P_PHEE_USERNAME 2>/dev/null || echo mifos)"
PHEE_PASSWORD="$(crudini --get "$CONFIG_FILE" \
  openg2p OPENG2P_PHEE_PASSWORD 2>/dev/null || echo password)"
PHEE_AUTHORIZATION="Basic $(printf '%s:%s' \
  "$PHEE_CLIENT_ID" "$PHEE_CLIENT_SECRET" | base64 | tr -d '\n')"

OPENG2P_NAMESPACE="$(crudini --get "$CONFIG_FILE" openg2p OPENG2P_NAMESPACE 2>/dev/null || echo openg2p)"
NS="$OPENG2P_NAMESPACE"
GAZELLE_DOMAIN="$(crudini --get "$CONFIG_FILE" general GAZELLE_DOMAIN 2>/dev/null || echo mifos.gazelle.test)"
FINERACT_BASE="https://mifos.${GAZELLE_DOMAIN}/fineract-provider/api/v1"

# Dependency namespaces, checked upfront by preflight_dependencies.
MIFOSX_NAMESPACE="$(crudini --get "$CONFIG_FILE" mifosx MIFOSX_NAMESPACE 2>/dev/null || echo mifosx)"
PH_NAMESPACE="$(crudini --get "$CONFIG_FILE" paymenthub PH_NAMESPACE 2>/dev/null || echo paymenthub)"
VNEXT_NAMESPACE="$(crudini --get "$CONFIG_FILE" vnext VNEXT_NAMESPACE 2>/dev/null || echo vnext)"

# Endpoint the connector POSTs the batch CSV to. Defined after PH_NAMESPACE
# because it is DERIVED from it — with the namespace hardcoded, renaming it left
# this pointing at a dead service while the preflight still passed. In-cluster DNS
# is used, as the ingress host does not resolve inside the pod.
# OPENG2P_PHEE_PAYMENT_ENDPOINT overrides the whole URL.
PHEE_PAYMENT_ENDPOINT="$(crudini --get "$CONFIG_FILE" \
  openg2p OPENG2P_PHEE_PAYMENT_ENDPOINT 2>/dev/null)"
if [[ -z "$PHEE_PAYMENT_ENDPOINT" ]]; then
  PHEE_BULK_SVC="ph-ee-bulk-processor.${PH_NAMESPACE}:80"
  PHEE_PAYMENT_ENDPOINT="http://${PHEE_BULK_SVC}/batchtransactions"
fi

# Payment Hub's operations API, which the connector reads the outcome of a sent batch
# back from (see setup-pbms-phee.sh, step_callback_config). Derived from PH_NAMESPACE
# for the same reason as the payment endpoint. OPENG2P_PHEE_OPS_ENDPOINT overrides it.
PHEE_OPS_ENDPOINT="$(crudini --get "$CONFIG_FILE" \
  openg2p OPENG2P_PHEE_OPS_ENDPOINT 2>/dev/null)"
if [[ -z "$PHEE_OPS_ENDPOINT" ]]; then
  PHEE_OPS_ENDPOINT="http://ph-ee-operations-app.${PH_NAMESPACE}:80/api/v1/batch"
fi

# Base URL Payment Hub posts batch progress back to, as reachable from ITS namespace.
# Set here as well as in setup-pbms-phee.sh because that script runs during the deploy,
# before this one has created the payment manager: on a fresh database its config step
# finds no manager to configure, and a manager created afterwards without this sends no
# X-CallbackURL at all. Defined after OPENG2P_NAMESPACE, which it is derived from.
PHEE_CB_BASE_URL="http://pbms-odoo.${OPENG2P_NAMESPACE}.svc.cluster.local"

# --- vNext ALS oracle sync (see sync_vnext_oracle) --------------------------
# The switch resolves "which FSP owns this MSISDN" from a MongoDB-backed oracle.
# We populate it through the supported FSPIOP API rather than writing to the DB:
# POST /participants/MSISDN/<msisdn> publishes a Kafka association event that
# account-lookup-svc persists. Idempotent, returns 202. The FSP must be a
# registered switch participant, which is why only bluebank clients are mirrored.
# fspiop-api-svc is a ClusterIP with no external ingress for this path, so the POST
# goes from inside the cluster via a short-lived curl pod.
FSPIOP_API_SVC="fspiop-api-svc.${VNEXT_NAMESPACE}:4000"
# The Fineract tenant a mirrored client belongs to IS its vNext fspId.
VNEXT_PAYEE_FSPID="bluebank"
# Mongo (read-only), used ONLY to verify an association really persisted — a 202
# alone does not prove it. Credentials are read at runtime from the infra chart by
# resolve_mongo_credentials(), never copied here where they could drift.
MONGO_NAMESPACE="$(crudini --get "$CONFIG_FILE" infra INFRA_NAMESPACE 2>/dev/null || echo infra)"
MONGO_POD="mongodb-0"
MONGO_CONTAINER="mongodb"
MONGO_DB="account-lookup"
MONGO_COLLECTION="builtinOracleParties"
# The chart that declares the MongoDB credentials. deployer.sh installs it with
# no values file and no --set overrides, so this file is the definitive source.
INFRA_VALUES_FILE="${RUN_DIR}/src/deployer/helm/infra/values.yaml"
# Read in main() — see resolve_mongo_credentials(). Empty means "cannot verify".
MONGO_USER=""
MONGO_PASS=""

# Callers run us in a subshell without exporting `debug` — default it for set -u.
debug="${debug:-false}"

#------------------------------------------------------------------------------
# Function : _find_pbms_pod
# Description: Finds the running pbms-odoo pod in the OpenG2P namespace.
# Returns: pod name on stdout, or empty if none is Running.
#------------------------------------------------------------------------------
_find_pbms_pod() {
  kubectl get pods -n "$NS" --no-headers 2>/dev/null \
    | awk '/^pbms-odoo-/ && $3=="Running"{print $1; exit}'
}

#------------------------------------------------------------------------------
# Function : _odoo_shell
# Description: Pipes a python heredoc (on stdin) into `odoo shell` in the pod.
# Parameters:
#   $1 - pod name
#   $2 - sentinel string the heredoc must print for success
# Returns: 0 if the sentinel was seen in the shell's output, 1 otherwise.
#------------------------------------------------------------------------------
_odoo_shell() {
  local pod="$1" sentinel="$2"
  # Plain grep, not grep -q: -q exits on first match, SIGPIPEing the upstream
  # kubectl exec, which under `set -o pipefail` reads as a false failure.
  kubectl exec -i -n "$NS" "$pod" -- \
    bash -lc "odoo shell -c /etc/odoo/odoo.conf -d '$ODOO_DB' --no-http 2>/dev/null" \
    | grep "$sentinel" >/dev/null
}

#------------------------------------------------------------------------------
# Function : _app_running
# Description: Liveness check for a dependency app — true when its namespace has
#              at least one fully-Ready pod. Self-contained rather than sourcing
#              core.sh, since this is a standalone util.
# Parameters:
#   $1 - namespace to check
# Returns: 0 if the namespace has >=1 Ready pod, 1 otherwise.
#------------------------------------------------------------------------------
_app_running() {
  local namespace="$1"
  kubectl get namespace "$namespace" >/dev/null 2>&1 || return 1
  local ready
  ready=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null \
    | awk '{split($2,a,"/"); if (a[1]==a[2] && a[1]>0) c++} END{print c+0}')
  [[ "${ready:-0}" -gt 0 ]]
}

#------------------------------------------------------------------------------
# Function : _require_number
# Description: Aborts unless a config value is a plain non-negative number. The
#              amounts are interpolated into the Python payloads as bare numeric
#              literals, so a typo would otherwise surface as a SyntaxError inside
#              `odoo shell`, after registrants had already been created.
# Parameters:
#   $1 - config key name, for the message
#   $2 - value to check
# Returns: nothing; exits 1 when the value is not numeric.
#------------------------------------------------------------------------------
_require_number() {
  local name="$1" value="$2"
  if [[ ! "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    log_error "config.ini [openg2p] $name must be a number, got '$value'"
    exit 1
  fi
}

#------------------------------------------------------------------------------
# Function : _infra_mongo_setting
# Description: Reads one key out of the mongodb.settings block of the infra
#              chart's values.yaml. awk rather than a YAML library, because only
#              the python3 stdlib is a declared dependency here.
# Globals: reads INFRA_VALUES_FILE.
# Parameters:
#   $1 - key name inside mongodb.settings (e.g. rootPassword)
# Outputs: the value on stdout, empty when the key or the file is absent.
#------------------------------------------------------------------------------
_infra_mongo_setting() {
  [[ -f "$INFRA_VALUES_FILE" ]] || return 0
  awk -v key="$1" '
    /^mongodb:/                                  { in_mongo = 1; next }
    in_mongo && /^[^ \t#]/                       { exit }
    in_mongo && /^  settings:/                   { in_settings = 1; next }
    in_mongo && in_settings && /^  [^ \t]/       { in_settings = 0 }
    in_settings && $1 == key":" {
      sub(/^[^:]*:[ \t]*/, "")   # drop "key:" and the following whitespace
      sub(/[ \t]+$/, "")         # drop trailing whitespace
      gsub(/^"|"$/, "")          # drop surrounding double quotes, if any
      print
      exit
    }
  ' "$INFRA_VALUES_FILE"
}

#------------------------------------------------------------------------------
# Function : resolve_mongo_credentials
# Description: Reads the MongoDB root credentials for the read-only oracle check.
#              They come from the infra chart's values.yaml, the one place they
#              are declared: deployer.sh installs that chart with no values file
#              and no --set overrides, so the file is what the cluster runs.
# Globals: sets MONGO_USER and MONGO_PASS; reads INFRA_VALUES_FILE.
# Returns: 0 when both are found, 1 otherwise (verification then degrades to a
#          warning — the registration POSTs still happen either way).
#------------------------------------------------------------------------------
resolve_mongo_credentials() {
  MONGO_USER="$(_infra_mongo_setting rootUsername)"
  MONGO_PASS="$(_infra_mongo_setting rootPassword)"
  [[ -n "$MONGO_USER" && -n "$MONGO_PASS" ]]
}

#------------------------------------------------------------------------------
# Function : preflight_dependencies
# Description: Verifies mifosx (source of the clients), paymenthub (the batch
#              target) and vnext (the oracle) are running before any work is done,
#              naming the missing app rather than doing partial work.
# Returns: 0 if all three are running, 1 otherwise (caller should abort).
#------------------------------------------------------------------------------
preflight_dependencies() {
  log_step "Checking dependencies are running (mifosx, paymenthub, vnext)"
  local missing=()
  _app_running "$MIFOSX_NAMESPACE" || missing+=("mifosx")
  _app_running "$PH_NAMESPACE"     || missing+=("paymenthub")
  _app_running "$VNEXT_NAMESPACE"  || missing+=("vnext")

  if [[ "${#missing[@]}" -gt 0 ]]; then
    log_failed "not running: ${missing[*]}"
    log_error "OpenG2P data setup needs mifosx, paymenthub and vnext running alongside it."
    log_error "Deploy the missing app(s) first, e.g.:  ./run.sh -m deploy -a ${missing[0]}"
    return 1
  fi
  log_ok
  return 0
}

#------------------------------------------------------------------------------
# Function : fetch_fineract_clients
# Description: Step 1 — fetches clients from Fineract for each tenant in
#              FINERACT_TENANTS.
# Returns: one TSV line per client with a mobile number on stdout:
#          <tenant>\t<mobileNo>\t<displayName>
#------------------------------------------------------------------------------
fetch_fineract_clients() {
  local tenant
  for tenant in "${FINERACT_TENANTS[@]}"; do
    curl -s -k -H "Fineract-Platform-TenantId: ${tenant}" \
         -H "Authorization: ${FINERACT_AUTH}" \
         "${FINERACT_BASE}/clients?limit=1000" 2>/dev/null \
      | TENANT="$tenant" python3 -c '
import sys, os, json
tenant = os.environ["TENANT"]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for c in data.get("pageItems", []):
    mobile = (c.get("mobileNo") or "").strip()
    name = (c.get("displayName") or "").strip()
    if mobile and name:
        # strip any stray whitespace/newlines from name; TSV-safe
        name = " ".join(name.split())
        print("%s\t%s\t%s" % (tenant, mobile, name))
'
  done
}

#------------------------------------------------------------------------------
# Function : resolve_payer_msisdn
# Description: Looks up the payer tenant's client MSISDN from Fineract, so the demo
#              payer number is never pinned. Returns the first client with a mobile
#              number in PHEE_PAYER_TENANT, which seeds exactly one payer client.
# Returns: the payer MSISDN (digits) on stdout, or empty if none found.
#------------------------------------------------------------------------------
resolve_payer_msisdn() {
  curl -s -k -H "Fineract-Platform-TenantId: ${PHEE_PAYER_TENANT}" \
       -H "Authorization: ${FINERACT_AUTH}" \
       "${FINERACT_BASE}/clients?limit=1000" 2>/dev/null \
    | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for c in data.get("pageItems", []):
    m = "".join(ch for ch in (c.get("mobileNo") or "") if ch.isdigit())
    if m:
        print(m)
        break
'
}

#------------------------------------------------------------------------------
# Function : create_registrants
# Description: Step 2 — creates registrants in PBMS from the client TSV built
#              in step 1. Idempotent (matched on phone); excludes payer MSISDNs.
# Parameters:
#   $1 - pod name (running pbms-odoo pod)
#   $2 - client TSV from fetch_fineract_clients
#------------------------------------------------------------------------------
create_registrants() {
  local pod="$1" clients_tsv="$2"
  log_step "Creating PBMS registrants from Fineract clients"
  # The unquoted heredoc lets bash expand $clients_tsv into the python payload.
  # Guard the empty case: printf on an empty array emits a bogus '"",' entry.
  local exclude_py=""
  if [[ "${#EXCLUDE_MSISDNS[@]}" -gt 0 ]]; then
    exclude_py="$(printf '"%s",' "${EXCLUDE_MSISDNS[@]}")"
  fi
  _odoo_shell "$pod" REGISTRANTS_OK <<PYEOF
import hashlib, datetime

# TSV lines: "<tenant>\t<mobile>\t<name>" — one client per line.
raw = """${clients_tsv}"""
# Payers/registering institutions to exclude (identified by MSISDN, digits only).
EXCLUDE = {${exclude_py}}
P = env["res.partner"].sudo()
today = datetime.date.today()
created = skipped = excluded = 0

def digits(s):
    return "".join(ch for ch in s if ch.isdigit())

def birthdate_for(msisdn):
    # Deterministic age seeded from the MSISDN, so the split is stable across runs.
    seed = int(hashlib.sha256(msisdn.encode()).hexdigest(), 16)
    age = 10 + (seed % 71)  # 10..80 inclusive
    d = today - datetime.timedelta(days=age * 365 + (seed % 365))
    return d.isoformat()

for line in raw.splitlines():
    line = line.strip()
    if not line or "\t" not in line:
        continue
    parts = line.split("\t")
    if len(parts) < 3:
        continue
    tenant, mobile, name = parts[0], parts[1], "\t".join(parts[2:])
    msisdn = digits(mobile)
    if not msisdn:
        continue
    # Payer/registering institution — not a beneficiary; do not add to the registry.
    if msisdn in EXCLUDE:
        excluded += 1
        print("EXCLUDE(payer)", name, msisdn)
        continue
    # Idempotent: skip if a registrant with this phone already exists.
    existing = P.search([("is_registrant", "=", True), ("phone", "=", msisdn)], limit=1)
    if existing:
        skipped += 1
        print("SKIP", name, msisdn)
        continue
    bits = name.split(" ", 1)
    given = bits[0]
    family = bits[1] if len(bits) > 1 else ""
    P.create({
        "name": name,
        "given_name": given,
        "family_name": family,
        "is_registrant": True,
        "is_group": False,
        "birthdate": birthdate_for(msisdn),
        "registration_date": today.isoformat(),
        "phone": msisdn,  # raw MSISDN — routes the PHEE->Mojaloop payment
    })
    env.cr.commit()
    created += 1
    print("CREATED", name, msisdn)

total = P.search_count([("is_registrant", "=", True), ("is_group", "=", False)])
print("REGISTRANTS_OK created=%d skipped=%d excluded=%d total_individual=%d" % (created, skipped, excluded, total))
PYEOF
  if [[ $? -eq 0 ]]; then log_ok; else log_warn "registrant creation did not complete — check odoo logs on $pod"; fi
}

#------------------------------------------------------------------------------
# Function : create_demo_program
# Description: Step 3 — creates the demo program via OpenG2P's own create-program
#              wizard, so every default manager is wired the way the UI does it,
#              then enrolls the age-eligible subset as beneficiaries. Out-of-band
#              registrants stay filtered out. Idempotent.
# Parameters:
#   $1 - pod name (running pbms-odoo pod)
#------------------------------------------------------------------------------
create_demo_program() {
  local pod="$1"
  log_step "Creating '${DEMO_PROGRAM_NAME}' + managers (age ${ELIG_MIN_AGE}-${ELIG_MAX_AGE} eligibility, enroll eligible)"
  _odoo_shell "$pod" PROGRAM_OK <<PYEOF
import datetime

name = "${DEMO_PROGRAM_NAME}"
min_age = ${ELIG_MIN_AGE}
max_age = ${ELIG_MAX_AGE}
today = datetime.date.today()
# age in [min,max]  <=>  birthdate in [today - (max+1)y, today - min y]
lower = (today - datetime.timedelta(days=(max_age + 1) * 365)).isoformat()
upper = (today - datetime.timedelta(days=min_age * 365)).isoformat()
domain = "[('birthdate','>=','%s'),('birthdate','<=','%s')]" % (lower, upper)

Program = env["g2p.program"].sudo()
prog = Program.search([("name", "=", name)], limit=1)
if prog:
    print("PROGRAM_EXISTS", prog.id)
    # Keep the entitlement in sync on re-run, not just at first creation.
    if prog.entitlement_managers:
        ent_mgr = prog.entitlement_managers[0].manager_ref_id
        if "amount_per_cycle" in ent_mgr._fields and ent_mgr.amount_per_cycle != ${ENTITLEMENT_AMOUNT_PER_CYCLE}:
            ent_mgr.amount_per_cycle = ${ENTITLEMENT_AMOUNT_PER_CYCLE}
            env.cr.commit()
            print("ENTITLEMENT_AMOUNT_SYNCED", ${ENTITLEMENT_AMOUNT_PER_CYCLE})
else:
    # currency is USD, matching the demo savings currency.
    currency = env.ref("base.USD")
    wiz = env["g2p.program.create.wizard"].sudo().create({
        "name": name,
        "currency_id": currency.id,
        "eligibility_domain": domain,          # <-- age filter attaches to eligibility mgr
        "cycle_duration": 1,
        "amount_per_cycle": ${ENTITLEMENT_AMOUNT_PER_CYCLE},
        "amount_per_individual_in_group": 0.0,
        "entitlement_kind": "default",
        "target_type": "individual",
        "import_beneficiaries": "no",          # enrollment stays manual
    })
    wiz.create_program()
    env.cr.commit()
    prog = Program.search([("name", "=", name)], limit=1)
    print("PROGRAM_CREATED", prog.id)

# The wizard leaves approver_group_id UNSET, so approving a cycle raises "The cycle
# approver group is not specified!" and blocks payments. Set it to the admin group.
from odoo.addons.g2p_programs.models import constants as _g2p_const
cyc_mgr = prog.get_manager(_g2p_const.MANAGER_CYCLE)
if cyc_mgr and not cyc_mgr.approver_group_id:
    grp = env.ref("g2p_registry_base.group_g2p_admin", raise_if_not_found=False)
    if grp:
        cyc_mgr.approver_group_id = grp.id
        env.cr.commit()
        print("APPROVER_GROUP_SET", grp.id, grp.name)
    else:
        print("APPROVER_GROUP_WARN g2p_registry_base.group_g2p_admin not found — cycle approval may fail")
else:
    print("APPROVER_GROUP_OK", cyc_mgr.approver_group_id.id if cyc_mgr and cyc_mgr.approver_group_id else None)

# Report the managers that got wired (so a re-run/verify shows the full set).
for f in ["eligibility_managers", "cycle_managers", "entitlement_managers",
          "program_managers", "payment_managers"]:
    print("MANAGER %-24s count=%d" % (f, len(prog[f])))

# Enroll ONLY the in-band registrants, which is what makes the demo payable; the
# out-of-band ones stay visibly filtered out. Idempotent.
Partner = env["res.partner"].sudo()
Mem = env["g2p.program_membership"].sudo()
eligible = Partner.search([
    ("is_registrant", "=", True), ("is_group", "=", False),
    ("birthdate", ">=", lower), ("birthdate", "<=", upper),
])
added = 0
for pt in eligible:
    if not Mem.search([("partner_id", "=", pt.id), ("program_id", "=", prog.id)], limit=1):
        Mem.create({"partner_id": pt.id, "program_id": prog.id})
        added += 1
env.cr.commit()
try:
    prog.enroll_eligible_registrants()
    env.cr.commit()
except Exception as e:
    print("ENROLL_WARN", repr(e)[:120])
enrolled = Mem.search_count([("program_id", "=", prog.id), ("state", "=", "enrolled")])
print("ENROLLED memberships_added=%d enrolled_now=%d" % (added, enrolled))

# Informational: how many current registrants match the eligibility band.
elig = len(eligible)
total = env["res.partner"].sudo().search_count([("is_registrant", "=", True), ("is_group", "=", False)])
print("ELIGIBLE %d / %d registrants match age %d-%d" % (elig, total, min_age, max_age))
print("PROGRAM_OK")
PYEOF
  if [[ $? -eq 0 ]]; then log_ok; else log_warn "demo program setup did not complete — check odoo logs on $pod"; fi
}

#------------------------------------------------------------------------------
# Function : create_payment_manager
# Description: Step 4 — creates a PHEE payment manager on the demo program and
#              wires it in. The connector only uses payment_endpoint_url; the other
#              required endpoint/auth fields are placeholders. Idempotent.
# Parameters:
#   $1 - pod name (running pbms-odoo pod)
#------------------------------------------------------------------------------
create_payment_manager() {
  local pod="$1"
  log_step "Creating PHEE payment manager on '${DEMO_PROGRAM_NAME}' (payer ${PHEE_TENANT_ID})"
  _odoo_shell "$pod" PAYMENT_MGR_OK <<PYEOF
import uuid
prog = env["g2p.program"].sudo().search([("name", "=", "${DEMO_PROGRAM_NAME}")], limit=1)
if not prog:
    print("NO_PROGRAM")
else:
    Phee = env["g2p.program.payment.manager.phee"].sudo()
    Wire = env["g2p.program.payment.manager"].sudo()
    phee = Phee.search([("program_id", "=", prog.id)], limit=1)
    if phee:
        print("PHEE_MGR_EXISTS", phee.id)
        if not phee.create_batch:
            # Idempotent fix-up for managers created before create_batch was added.
            phee.create_batch = True
            env.cr.commit()
            print("PHEE_MGR_CREATE_BATCH_FIXED", phee.id)
        if phee.payment_mode != "MOJALOOP" or phee.payee_id_type_to_send:
            # Idempotent fix-up for managers created before the routing fix below.
            phee.payment_mode = "MOJALOOP"
            phee.payee_id_type_to_send = False
            env.cr.commit()
            print("PHEE_MGR_ROUTING_FIXED", phee.id)
    else:
        phee = Phee.create({
            "name": "PHEE",
            "program_id": prog.id,
            "payment_endpoint_url": "${PHEE_PAYMENT_ENDPOINT}",
            # Read back by the reconciliation added in setup-pbms-phee.sh, so these are
            # real endpoints and not placeholders any more: pointing them at the upload
            # URL is what makes a batch stay unreconciled.
            "status_endpoint_url": "${PHEE_OPS_ENDPOINT}",
            "details_endpoint_url": "${PHEE_OPS_ENDPOINT}",
            # required-but-unused-in-this-connector placeholder (no OAuth call is made):
            "auth_endpoint_url": "${PHEE_PAYMENT_ENDPOINT}",
            "authorization": "${PHEE_AUTHORIZATION}",
            "grant_type": "password",
            "tenant_id": "${PHEE_TENANT_ID}",
            "username": "${PHEE_USERNAME}",
            "password": "${PHEE_PASSWORD}",
            # MOJALOOP, not "bank": the payer routes through the vNext switch
            # (docs/GOVSTACK.md). "bank" is not a recognized mode and returns
            # "Failed / 404 Payment mode not configured" on every payment.
            "payment_mode": "MOJALOOP",
            "payer_id_type": "${PHEE_PAYER_ID_TYPE}",
            "payer_id": "${PHEE_PAYER_ID}",
            "payee_id_type": "${PHEE_PAYEE_ID_TYPE}",
            # Left unset: _get_dfsp_id_and_type() only falls back to its PHONE
            # default when this is falsy. The model's own default of ACCOUNT_ID
            # otherwise silently overrides payee_id_type=phone and sends the wrong
            # identifier type to Mojaloop.
            "payee_id_type_to_send": False,
            "batch_type_header": "csv",
            # Without this, prepare_payment() creates g2p.payment records but no
            # g2p.payment.batch, so "Send Payments" silently loops over zero
            # batches — no error, no HTTP call, no visible effect.
            "create_batch": True,
        })
        env.cr.commit()
        print("PHEE_MGR_CREATED", phee.id)
    # Callback wiring, for a manager just created and for one an earlier run left
    # unconfigured. The fields themselves are added by setup-pbms-phee.sh, hence the
    # guard: without this the manager sends no X-CallbackURL and every batch waits on
    # the reconcile scheduled action instead of being told when it progressed.
    if "callback_base_url" in phee._fields:
        cb = {}
        if not phee.callback_base_url:
            cb["callback_base_url"] = "${PHEE_CB_BASE_URL}"
        if not phee.callback_token:
            # Committed up front rather than generated on first send, which would write
            # it inside the transaction that posts the batch.
            cb["callback_token"] = uuid.uuid4().hex
        if not phee.callback_enabled:
            cb["callback_enabled"] = True
        if cb:
            phee.write(cb)
            env.cr.commit()
            print("PHEE_MGR_CALLBACK_SET", phee.id)
    ref = "g2p.program.payment.manager.phee,%d" % phee.id
    w = Wire.search([("program_id", "=", prog.id), ("manager_ref_id", "=", ref)], limit=1)
    if not w:
        w = Wire.create({"program_id": prog.id, "manager_ref_id": ref})
        env.cr.commit()
        print("WIRE_CREATED", w.id)
    else:
        print("WIRE_EXISTS", w.id)
    # payment_managers is an M2M constrained to ONE entry and is what
    # get_manager(MANAGER_PAYMENT) reads. REPLACE the wizard's default with the PHEE
    # wire — creating the wire above is not enough, the M2M must be set explicitly.
    prog.write({"payment_managers": [(6, 0, [w.id])]})
    env.cr.commit()
    prog.invalidate_recordset()
    active = [str(r.manager_ref_id) for r in prog.payment_managers]
    print("PAYMENT_MGR_OK endpoint=%s tenant=%s active=%s" % (phee.payment_endpoint_url, phee.tenant_id, active))
PYEOF
  if [[ $? -eq 0 ]]; then log_ok; else log_warn "payment manager setup did not complete — check odoo logs on $pod"; fi
}

#------------------------------------------------------------------------------
# Function : create_program_fund
# Description: Step 5 — funds the demo program so it has a pool to pay
#              entitlements from. Idempotent: skips if a POSTED fund exists.
#              Does not resize existing funds — a posted fund cannot be deleted,
#              only cancelled in the UI.
# Parameters:
#   $1 - pod name (running pbms-odoo pod)
#------------------------------------------------------------------------------
create_program_fund() {
  local pod="$1"
  log_step "Funding '${DEMO_PROGRAM_NAME}' with \$${PROGRAM_FUND_AMOUNT} (g2p.program.fund)"
  _odoo_shell "$pod" FUND_OK <<PYEOF
import datetime

prog = env["g2p.program"].sudo().search([("name", "=", "${DEMO_PROGRAM_NAME}")], limit=1)
if not prog:
    print("NO_PROGRAM")
else:
    Fund = env["g2p.program.fund"].sudo()
    existing = Fund.search([("program_id", "=", prog.id), ("state", "=", "posted")])
    if existing:
        print("FUND_EXISTS", existing.ids, "total=%s" % sum(existing.mapped("amount")))
    else:
        fund = Fund.create({
            "name": "Initial funding",
            "program_id": prog.id,
            "amount": ${PROGRAM_FUND_AMOUNT},
            "date_posted": datetime.date.today().isoformat(),
            "state": "posted",
        })
        env.cr.commit()
        print("FUND_CREATED", fund.id, fund.amount)
print("FUND_OK")
PYEOF
  if [[ $? -eq 0 ]]; then log_ok; else log_warn "program fund setup did not complete — check odoo logs on $pod"; fi
}

#------------------------------------------------------------------------------
# Function : _fspiop_register_party
# Description: POSTs one FSPIOP participant association from inside the cluster
#              via a short-lived curl pod, registering an MSISDN->fspId mapping in
#              the vNext ALS oracle. The one-shot pod delete is best-effort.
# Parameters:
#   $1 - msisdn (digits only)
#   $2 - fspId to associate the msisdn with
# Returns: HTTP status code on stdout (or "000" if the pod never completed).
#------------------------------------------------------------------------------
_fspiop_register_party() {
  local msisdn="$1" fspid="$2"
  local pod="oracle-register-${msisdn}"
  kubectl run "$pod" --restart=Never --image=curlimages/curl -n "$VNEXT_NAMESPACE" \
    --command -- sh -c "curl -s -o /dev/null -w '%{http_code}' -X POST \
      'http://${FSPIOP_API_SVC}/participants/MSISDN/${msisdn}' \
      -H 'Content-Type: application/vnd.interoperability.participants+json;version=1.1' \
      -H 'Accept: application/vnd.interoperability.participants+json;version=1.1' \
      -H 'FSPIOP-Source: ${fspid}' \
      -H 'Date: Thu, 01 Jan 2026 00:00:00 GMT' \
      -d '{\"fspId\":\"${fspid}\",\"currency\":\"USD\"}'" >/dev/null 2>&1
  # Wait for the one-shot pod to finish, then read the status code it printed.
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$pod" \
    -n "$VNEXT_NAMESPACE" --timeout=30s >/dev/null 2>&1
  local code
  code="$(kubectl logs -n "$VNEXT_NAMESPACE" "$pod" 2>/dev/null | tr -dc '0-9')"
  kubectl delete pod "$pod" -n "$VNEXT_NAMESPACE" --wait=false >/dev/null 2>&1
  printf '%s' "${code:-000}"
}

#------------------------------------------------------------------------------
# Function : _oracle_has_party
# Description: Read-only check that an MSISDN->fspId association persisted in the
#              Mongo oracle. All writes go through _fspiop_register_party.
# Parameters:
#   $1 - msisdn (digits only)
#   $2 - fspId the association is expected to have
# Returns: matching document count on stdout (0 if not yet persisted).
#------------------------------------------------------------------------------
_oracle_has_party() {
  local msisdn="$1" fspid="$2"
  kubectl exec -i -n "$MONGO_NAMESPACE" "$MONGO_POD" -c "$MONGO_CONTAINER" -- \
    mongosh --quiet -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase admin "$MONGO_DB" \
    --eval "db.${MONGO_COLLECTION}.countDocuments({partyId:\"${msisdn}\",fspId:\"${fspid}\"})" 2>/dev/null \
    | tr -dc '0-9'
}

#------------------------------------------------------------------------------
# Function : sync_vnext_oracle
# Description: Step 6 — registers every mirrored client in the vNext ALS oracle so
#              it resolves at transfer-time party lookup, via the FSPIOP
#              participants API (see the block comment near the top). Payer MSISDNs
#              are excluded. Non-fatal: a hiccup only means some payees won't route.
# Parameters:
#   $1 - client TSV from fetch_fineract_clients
#------------------------------------------------------------------------------
sync_vnext_oracle() {
  local clients_tsv="$1"
  log_step "Registering mirrored clients in vNext ALS oracle (FSPIOP participants API @ ${FSPIOP_API_SVC})"

  # Skip cleanly if vNext isn't present (e.g. PBMS-only cluster).
  if ! kubectl get svc -n "$VNEXT_NAMESPACE" fspiop-api-svc >/dev/null 2>&1; then
    log_warn "fspiop-api-svc not found in namespace '$VNEXT_NAMESPACE' — skipping oracle sync (is vNext deployed?)"
    return 0
  fi

  # Payer MSISDNs (digits only) to skip — never beneficiaries / oracle payees.
  local exclude_re
  exclude_re="$(IFS='|'; echo "${EXCLUDE_MSISDNS[*]}")"

  local registered=0 verified=0 failed=0 unverified=0
  # TSV on FD 3, not stdin: the kubectl calls in the body would consume the loop's
  # stdin and truncate it to one iteration.
  while IFS=$'\t' read -r -u 3 tenant mobile _name; do
    [[ -z "${mobile:-}" ]] && continue
    local msisdn fspid
    msisdn="${mobile//[!0-9]/}"      # digits only
    fspid="$tenant"                  # bluebank (only tenant mirrored) == vNext fspId
    [[ -z "$msisdn" ]] && continue
    if [[ -n "$exclude_re" ]] && [[ "$msisdn" =~ ^(${exclude_re})$ ]]; then
      continue
    fi

    # Register via the FSPIOP participants API (idempotent; 202 on accept).
    local code
    code="$(_fspiop_register_party "$msisdn" "$fspid")"
    registered=$((registered+1))
    log_with_verbose_check "$debug" "$DEBUG" "FSPIOP register ${msisdn} -> ${fspid} (HTTP ${code})"

    # Without Mongo credentials the read-only check cannot run. The POST above
    # still happened, so count it unverified rather than report a false failure.
    if [[ -z "$MONGO_PASS" ]]; then
      unverified=$((unverified+1))
      continue
    fi

    # Processed asynchronously off Kafka, so poll until it shows up rather than
    # reporting success on the 202 alone.
    local present=0 i
    for i in 1 2 3 4 5 6; do
      if [[ "$(_oracle_has_party "$msisdn" "$fspid")" != "0" ]]; then present=1; break; fi
      sleep 2
    done
    if [[ "$present" == "1" ]]; then
      verified=$((verified+1))
      log_with_verbose_check "$debug" "$DEBUG" "ORACLE_OK ${msisdn} -> ${fspid}"
    else
      failed=$((failed+1))
      log_warn "oracle association for ${msisdn} -> ${fspid} did not persist (last POST HTTP ${code}); payee may fail party lookup"
    fi
  done 3< <(printf '%s\n' "$clients_tsv")

  if [[ "$registered" -eq 0 ]]; then
    log_warn "no MSISDNs to register in the oracle — skipping"
  elif [[ "$unverified" -gt 0 ]]; then
    log_warn "registered ${unverified}/${registered} payee(s) but could not" \
      "verify them — see the MongoDB credential warning above"
  elif [[ "$failed" -eq 0 ]]; then
    log_ok
    log_with_verbose_check "$debug" "$DEBUG" \
      "oracle sync: registered=${registered} verified=${verified} failed=${failed}"
  else
    log_warn "vNext oracle sync incomplete — ${failed}/${registered} payee(s) failed to persist; they may fail party lookup"
  fi
}

#------------------------------------------------------------------------------
# main
#------------------------------------------------------------------------------
main() {
  log_section "Populating PBMS registry demo data (namespace: $NS)"

  command -v kubectl >/dev/null 2>&1 || { log_error "kubectl not found on PATH"; exit 1; }
  command -v crudini >/dev/null 2>&1 || { log_error "crudini not found on PATH"; exit 1; }
  command -v curl    >/dev/null 2>&1 || { log_error "curl not found on PATH"; exit 1; }
  command -v python3 >/dev/null 2>&1 || { log_error "python3 not found on PATH"; exit 1; }

  # Fail fast on a bad amount before any registrant exists (_require_number).
  _require_number OPENG2P_ENTITLEMENT_AMOUNT_PER_CYCLE \
    "$ENTITLEMENT_AMOUNT_PER_CYCLE"
  _require_number OPENG2P_PROGRAM_FUND_AMOUNT "$PROGRAM_FUND_AMOUNT"

  # Abort early with a clear message if mifosx / paymenthub / vnext isn't up.
  preflight_dependencies || exit 1

  # Read-only MongoDB credentials for the oracle verification in step 6.
  # Non-fatal: without them the FSPIOP registrations still happen, unconfirmed.
  if ! resolve_mongo_credentials; then
    log_warn "no mongodb.settings.rootUsername/rootPassword in" \
      "$INFRA_VALUES_FILE"
    log_warn "  vNext oracle associations will be registered but not verified."
  fi

  local pod
  pod="$(_find_pbms_pod)"
  if [[ -z "$pod" ]]; then
    log_error "no Running pbms-odoo pod in namespace '$NS' — deploy PBMS first (./run.sh -m deploy -a openg2p)"
    exit 1
  fi
  log_with_level "$INFO" "Using pod: $pod"
  log_with_level "$INFO" "Reading clients from Fineract at ${FINERACT_BASE}"

  # Resolve the payer MSISDN unless config.ini pinned one. It drives both the
  # registry exclude list and the payment manager's payer_id.
  if [[ -n "$PHEE_PAYER_ID" ]]; then
    log_with_level "$INFO" \
      "Payer MSISDN pinned by config.ini [openg2p]: ${PHEE_PAYER_ID}"
    EXCLUDE_MSISDNS=("$PHEE_PAYER_ID")
  else
    log_step "Resolving payer MSISDN from tenant '${PHEE_PAYER_TENANT}'"
    PHEE_PAYER_ID="$(resolve_payer_msisdn)"
    if [[ -z "$PHEE_PAYER_ID" ]]; then
      log_warn "no client with a mobile number found in tenant" \
        "'${PHEE_PAYER_TENANT}' — payer will not be excluded/wired" \
        "(is MifosX seeded?)"
    else
      EXCLUDE_MSISDNS=("$PHEE_PAYER_ID")
      log_ok
      log_with_level "$INFO" \
        "Payer: ${PHEE_PAYER_TENANT} MSISDN ${PHEE_PAYER_ID}"
    fi
  fi

  # Step 1 — fetch clients from Fineract.
  log_step "Fetching clients from Fineract (${FINERACT_TENANTS[*]})"
  local clients_tsv client_count
  clients_tsv="$(fetch_fineract_clients)"
  client_count="$(printf '%s\n' "$clients_tsv" | grep -c . || true)"
  if [[ -z "$clients_tsv" || "$client_count" -eq 0 ]]; then
    log_warn "no clients with mobile numbers found in Fineract — is MifosX deployed and seeded? (./run.sh -m deploy -a mifosx)"
    log_warn "skipping registrant creation; nothing to do"
    exit 0
  fi
  log_ok
  log_with_level "$INFO" "Found $client_count client(s) with mobile numbers"

  # Step 2 — create registrants.
  create_registrants "$pod" "$clients_tsv"

  # Step 3 — create the demo program.
  create_demo_program "$pod"

  # Step 4 — create + wire the PHEE payment manager on the demo program.
  create_payment_manager "$pod"

  # Step 5 — fund the demo program.
  create_program_fund "$pod"

  # Step 6 — register the mirrored clients in the vNext ALS oracle so they resolve
  # at party-lookup time (otherwise PHEE->Mojaloop payments fail before reaching Fineract).
  sync_vnext_oracle "$clients_tsv"

  # Verify login still serves (matches setup-pbms-phee.sh's final check).
  log_step "Verifying /web/login serves (200)"
  local code
  code="$(kubectl exec -n "$NS" "$pod" -- bash -lc 'curl -s -o /dev/null -w "%{http_code}" http://localhost:8069/web/login' 2>/dev/null)"
  if [[ "$code" == "200" ]]; then log_ok; else log_warn "login returned HTTP $code — check: kubectl logs -n $NS $pod | grep -i error"; fi

  log_banner "PBMS registry demo data setup complete"
  log_with_level "$INFO" "Registry: PBMS UI -> Registry -> Individuals should list the clients."
  log_with_level "$INFO" "Program:  PBMS UI -> Programs -> '${DEMO_PROGRAM_NAME}' (age ${ELIG_MIN_AGE}-${ELIG_MAX_AGE} eligibility). Age-eligible registrants are enrolled; out-of-band ones are filtered out."
  log_with_level "$INFO" "Payments: a PHEE payment manager is wired to the program (endpoint ${PHEE_PAYMENT_ENDPOINT}, payer ${PHEE_TENANT_ID}). Trigger the batch manually after enrollment."
  log_with_level "$INFO" "Funding:  program funded with \$${PROGRAM_FUND_AMOUNT} (entitlement \$${ENTITLEMENT_AMOUNT_PER_CYCLE}/beneficiary/cycle)."
  log_with_level "$INFO" "Routing:  mirrored clients registered in the vNext ALS oracle (fspId=${VNEXT_PAYEE_FSPID}) so party lookup resolves them for PHEE->Mojaloop payments."
}

main "$@"
