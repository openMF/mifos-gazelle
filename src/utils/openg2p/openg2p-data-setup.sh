#!/usr/bin/env bash
#------------------------------------------------------------------------------
# openg2p-data-setup.sh -- populate the PBMS (OpenG2P) built-in registry as a demo
# environment: mirror the clients that exist in the deployed MifosX/Fineract into
# the PBMS registry as individual registrants, and create a demo program with an
# age-based eligibility filter (so a subset can be filtered out). Enrollment is a
# manual task and is deliberately NOT performed here.
#
# Runs against the live cluster, driven via `kubectl exec ... odoo shell` on the
# running pbms-odoo pod — the same proven pattern as setup-pbms-phee.sh. Safe to
# re-run: registrant creation is idempotent (matched on phone), and the program is
# only created if absent. Failures log a WARN and continue (non-fatal), so this is
# safe to call from the post-deploy chain.
#
# Why query live MifosX instead of regenerating? The demo clients in a Gazelle
# cluster are created by generate-mifos-vnext-data.py, which is typically run with
# non-deterministic MSISDNs/names — so re-running the generator produces DIFFERENT
# people. To get "the same clients" we read the actual clients out of Fineract.
#
# Phone note: the PHEE->Mojaloop payment routes on res.partner.phone (the plain
# char field), and the vNext oracle registered parties under the RAW MSISDN. So we
# store the raw MSISDN in res.partner.phone and do NOT populate the E.164-validated
# g2p.phone.number child (which would reject the synthetic AU-style 04xx numbers
# and is not needed for routing).
#
# Steps:
#   1  Fetch clients (displayName + mobileNo) from Fineract per tenant.
#   2  Create each as an individual res.partner registrant in PBMS (raw MSISDN in
#      phone, deterministic birthdate seeded from the MSISDN for a stable age split).
#   3  Create the "Demo Program" with an age-based eligibility_domain (no enrollment).
#   4  Create + wire a PHEE payment manager on the program (so batches can be issued
#      to Payment Hub EE). Enrollment/triggering the batch remains a manual task.
#   5  Fund the program (g2p.program.fund) with a starting balance.
#   6  Register the mirrored clients in the vNext ALS oracle so PHEE->Mojaloop
#      party lookup resolves them (see sync_vnext_oracle).
#------------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONFIG_FILE="${RUN_DIR}/config/config.ini"

# shellcheck source=/dev/null
source "${RUN_DIR}/src/utils/logger.sh"

ODOO_DB="pbmsdb"
# Fineract clients we mirror into the registry as beneficiaries.
# ONLY bluebank: it is the sole tenant onboarded as a Payee FSP / participant in the
# vNext switch (docs/GOVSTACK.md "Tenant Architecture"). greenbank is the payer and
# redbank is NOT registered as a vNext participant, so payments to redbank payees fail
# at party lookup ("No destination participant found for fspId: redbank"). Mirroring
# only bluebank clients keeps every registrant payable end-to-end.
# (The greenbank payer client is excluded by its resolved MSISDN — see
# PHEE_PAYER_TENANT / resolve_payer_msisdn — even if it ever appears here.)
FINERACT_TENANTS=(bluebank)
# mifos:password — same basic-auth the data-loading scripts use against Fineract.
FINERACT_AUTH="Basic bWlmb3M6cGFzc3dvcmQ="

# The payer tenant (a Fineract tenant, NOT an MSISDN). greenbank is the demo payer.
# Its client's MSISDN is looked up from Fineract at runtime (resolve_payer_msisdn),
# not hardcoded — the demo dump's MSISDNs are regenerated periodically, so a fixed
# number goes stale. That resolved MSISDN feeds both EXCLUDE_MSISDNS (below) and the
# PHEE payment manager's payer_id (step 4).
PHEE_PAYER_TENANT="greenbank"

# Clients to exclude from the registry — payers/registering institutions, not
# beneficiaries. Identified by MSISDN (digits only; unique and stable, unlike names).
# Populated at runtime in main() with the resolved PHEE_PAYER_TENANT MSISDN.
EXCLUDE_MSISDNS=()

# Demo program config. The eligibility domain selects registrants whose age falls in
# [ELIG_MIN_AGE, ELIG_MAX_AGE]; registrants outside the band are the "filtered out" set.
# With the deterministic per-MSISDN ages of the seeded bluebank clients, 18-70 yields
# 4 eligible (e.g. Gabriel 26, James 26, Caleb 64, Nathan 67) and filters out the
# minor (Scarlett 14) and the eldest (Sophia 73) — a clean, small demo batch that
# also keeps the concurrent PHEE->Mojaloop burst low.
DEMO_PROGRAM_NAME="Demo Program"
ELIG_MIN_AGE=18
ELIG_MAX_AGE=70
# Entitlement per beneficiary per cycle, and the program's funding pool (g2p.program.fund).
ENTITLEMENT_AMOUNT_PER_CYCLE=50.0
PROGRAM_FUND_AMOUNT=1000.0

# PHEE payment manager config for the demo program. The g2p_payment_phee connector
# POSTs the batch CSV (multipart) to PAYMENT_ENDPOINT with headers Platform-TenantId
# + Type:csv; it does NOT do the OAuth dance in this version, so auth/status/details
# URLs + authorization/grant_type are required-but-unused placeholders.
# In-cluster service DNS is used (the *.gazelle.test ingress host does not resolve
# from inside the pbms pod). Payer = the PHEE_PAYER_TENANT (greenbank) client, whose
# MSISDN (PHEE_PAYER_ID) is resolved from Fineract at runtime — see main().
PHEE_PAYMENT_ENDPOINT="http://paymenthub-ee-bulk-processor.paymenthub:80/batchtransactions"
PHEE_TENANT_ID="$PHEE_PAYER_TENANT"
PHEE_PAYER_ID_TYPE="msisdn"
PHEE_PAYER_ID=""            # resolved at runtime from PHEE_PAYER_TENANT (main)
PHEE_PAYEE_ID_TYPE="phone"

OPENG2P_NAMESPACE="$(crudini --get "$CONFIG_FILE" openg2p OPENG2P_NAMESPACE 2>/dev/null || echo openg2p)"
NS="$OPENG2P_NAMESPACE"
GAZELLE_DOMAIN="$(crudini --get "$CONFIG_FILE" general GAZELLE_DOMAIN 2>/dev/null || echo mifos.gazelle.test)"
FINERACT_BASE="https://mifos.${GAZELLE_DOMAIN}/fineract-provider/api/v1"

# Namespaces of the three apps this script depends on being deployed and running
# alongside OpenG2P (checked upfront by preflight_dependencies):
#   mifosx     — source of the clients we mirror into the registry (Fineract API)
#   paymenthub — the PHEE bulk-processor the payment manager POSTs batches to
#   vnext      — the switch whose ALS oracle we register payees in (step 6)
MIFOSX_NAMESPACE="$(crudini --get "$CONFIG_FILE" mifosx MIFOSX_NAMESPACE 2>/dev/null || echo mifosx)"
PH_NAMESPACE="$(crudini --get "$CONFIG_FILE" paymenthub PH_NAMESPACE 2>/dev/null || echo paymenthub)"
VNEXT_NAMESPACE="$(crudini --get "$CONFIG_FILE" vnext VNEXT_NAMESPACE 2>/dev/null || echo vnext)"

# --- vNext ALS oracle sync (see sync_vnext_oracle) --------------------------
# At transfer time the vNext switch resolves "which FSP owns this MSISDN" from the
# built-in ALS oracle backed by MongoDB (account-lookup.builtinOracleParties), read
# by account-lookup-svc via its MongoOracleProviderRepo. To populate that store
# through a supported API (no direct DB writes), we call the FSPIOP participant-
# registration endpoint on fspiop-api-svc:
#
#   POST /participants/MSISDN/<msisdn>   body {"fspId","currency"}   FSPIOP-Source: <fsp>
#
# That publishes a ParticipantAssociationRequestReceivedEvt onto Kafka; the
# account-lookup aggregate validates the FSP is a registered switch participant and
# then persists the association to Mongo (MongoOracleProviderRepo.associateParticipant).
# The endpoint returns 202 and is idempotent (a re-POST of an existing party is a
# no-op, no duplicate). NOTE the FSP MUST be a registered, active participant in the
# switch — bluebank is (see participants BC); redbank is NOT, so it would be rejected.
# We only mirror bluebank clients (FINERACT_TENANTS), so every record's fspId=bluebank.
#
# fspiop-api-svc is a ClusterIP with no working external ingress for this path, so we
# POST from inside the cluster via a short-lived curl pod (kubectl run), matching how
# the rest of this script reaches in-cluster services. (VNEXT_NAMESPACE is defined
# with the other dependency namespaces near the top.)
FSPIOP_API_SVC="fspiop-api-svc.${VNEXT_NAMESPACE}:4000"
# The Fineract tenant each mirrored client belongs to IS its vNext fspId. We only
# mirror bluebank clients, so this is the fspId used for every oracle record.
VNEXT_PAYEE_FSPID="bluebank"
# Mongo (read-only) coordinates — used ONLY to verify each association actually
# persisted after the async event is processed (a POST 202 alone doesn't prove it).
MONGO_NAMESPACE="$(crudini --get "$CONFIG_FILE" infra INFRA_NAMESPACE 2>/dev/null || echo infra)"
MONGO_POD="mongodb-0"
MONGO_CONTAINER="mongodb"
MONGO_USER="root"
MONGO_PASS="mongoDbPas42"
MONGO_DB="account-lookup"
MONGO_COLLECTION="builtinOracleParties"

# Verbose flag for log_with_verbose_check. Callers run us in a fresh subshell and do
# not export `debug`; under `set -u` an unbound "$debug" would abort. Default it.
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
#              Mirrors setup-pbms-phee.sh's _odoo_shell.
# Parameters:
#   $1 - pod name
#   $2 - sentinel string the heredoc must print for success
# Returns: 0 if the sentinel was seen in the shell's output, 1 otherwise.
#------------------------------------------------------------------------------
_odoo_shell() {
  local pod="$1" sentinel="$2"
  # Use `grep` (not `grep -q`): -q exits on first match, which SIGPIPEs the
  # upstream kubectl exec and — under `set -o pipefail` — would surface as a
  # false failure. Plain grep drains all output, so $? reflects match/no-match.
  kubectl exec -i -n "$NS" "$pod" -- \
    bash -lc "odoo shell -c /etc/odoo/odoo.conf -d '$ODOO_DB' --no-http 2>/dev/null" \
    | grep "$sentinel" >/dev/null
}

#------------------------------------------------------------------------------
# Function : _app_running
# Description: Lightweight liveness check for a dependency app — true when its
#              namespace exists and has at least one fully-Ready pod (all
#              containers ready, e.g. 1/1). Kept self-contained (rather than
#              sourcing the deployer's core.sh) since this is a standalone util.
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
# Function : preflight_dependencies
# Description: Verifies the three apps this script reads from / writes to are
#              deployed and running alongside OpenG2P before any work is done:
#                mifosx     — the clients we mirror into the registry come from
#                             Fineract; without it there is nothing to load
#                paymenthub — the PHEE bulk-processor the payment manager targets
#                vnext      — the switch whose ALS oracle we register payees in
#              Fails fast with a clear, actionable message naming the missing
#              app(s), instead of silently doing partial work.
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
#              payer number is never hardcoded (the demo dump's MSISDNs are
#              regenerated periodically — a fixed value goes stale). Returns the
#              first client with a mobile number in PHEE_PAYER_TENANT (the demo
#              seeds exactly one payer client there), digits only.
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
  # The unquoted heredoc lets bash expand $clients_tsv (a python-literal string of
  # the TSV) into the script before it is piped into odoo shell.
  # Build a python set literal of excluded MSISDNs (digits only) for the heredoc.
  # Guard the empty case: printf on an empty array would emit a bogus '"",' entry,
  # putting an empty string in the python set — harmless but sloppy. Emit nothing.
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
    # Deterministic age in [10, 80] seeded from the MSISDN, so the eligible/ineligible
    # split is stable across re-runs and the same client always gets the same age.
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
#              wizard, which sets up all the default managers in one transaction
#              (eligibility with our age domain, cycle, entitlement, program, and
#              a default payment manager) — the same path the "Create Program" UI
#              button runs. Idempotent (created only if absent). Then enrolls the
#              age-eligible subset as beneficiaries so the demo is payable without
#              a manual enrollment click; out-of-band registrants stay filtered out.
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
    # Keep the entitlement amount in sync on re-run (e.g. after tuning the config
    # above) rather than only applying it at first creation.
    if prog.entitlement_managers:
        ent_mgr = prog.entitlement_managers[0].manager_ref_id
        if "amount_per_cycle" in ent_mgr._fields and ent_mgr.amount_per_cycle != ${ENTITLEMENT_AMOUNT_PER_CYCLE}:
            ent_mgr.amount_per_cycle = ${ENTITLEMENT_AMOUNT_PER_CYCLE}
            env.cr.commit()
            print("ENTITLEMENT_AMOUNT_SYNCED", ${ENTITLEMENT_AMOUNT_PER_CYCLE})
else:
    # Use the create-program wizard so eligibility/cycle/entitlement/program/payment
    # managers are all created and wired the way the UI does it. amount_per_cycle is
    # the per-beneficiary entitlement; currency is USD (matches the demo savings ccy).
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

# The create-program wizard leaves the cycle manager's approver_group_id UNSET, so
# approving a cycle raises "The cycle approver group is not specified!" — blocking the
# cycle and therefore payments. Set it to the OpenG2P admin group (confirmed on the
# live instance: res.groups "Administrator", XML id g2p_registry_base.group_g2p_admin).
# Idempotent: only set when unset.
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

# Enroll ONLY the registrants inside the eligibility band as beneficiaries. This is
# what makes the demo end-to-end payable: the age domain filters the registry set,
# and the in-band subset become enrolled beneficiaries (the out-of-band ones — the
# minor and the eldest — are visibly "filtered out"). Idempotent: memberships are
# created only if absent, and enroll_eligible_registrants() only promotes in-band ones.
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
#              wires it in. Idempotent (created only if the program has no PHEE
#              manager yet). The g2p_payment_phee connector only actually uses
#              payment_endpoint_url (multipart CSV POST); the other required
#              endpoints/auth fields are set to placeholders. batch_type_header=csv
#              and payee_id_type=phone match what setup-pbms-phee.sh configures and
#              the registrant phones. create_batch=True is required for "Send
#              Payments" to do anything at all — see the comment at the create()
#              call below.
# Parameters:
#   $1 - pod name (running pbms-odoo pod)
#------------------------------------------------------------------------------
create_payment_manager() {
  local pod="$1"
  log_step "Creating PHEE payment manager on '${DEMO_PROGRAM_NAME}' (payer ${PHEE_TENANT_ID})"
  _odoo_shell "$pod" PAYMENT_MGR_OK <<PYEOF
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
            # required-but-unused-in-this-connector placeholders (no OAuth call is made):
            "auth_endpoint_url": "${PHEE_PAYMENT_ENDPOINT}",
            "status_endpoint_url": "${PHEE_PAYMENT_ENDPOINT}",
            "details_endpoint_url": "${PHEE_PAYMENT_ENDPOINT}",
            "authorization": "Basic Y2xpZW50Og==",
            "grant_type": "password",
            "tenant_id": "${PHEE_TENANT_ID}",
            "username": "mifos",
            "password": "password",
            # MOJALOOP (not "bank"): greenbank is configured as a Mojaloop payer
            # (docs/GOVSTACK.md "Understanding Payment Modes and Tenants" — greenbank
            # routes payment-transfer via PayerFundTransfer-{dfspid} through the vNext
            # switch). "bank" isn't a recognized routing mode and every payment came
            # back "Failed / 404 Payment mode not configured" — verified against a
            # live batch.
            "payment_mode": "MOJALOOP",
            "payer_id_type": "${PHEE_PAYER_ID_TYPE}",
            "payer_id": "${PHEE_PAYER_ID}",
            "payee_id_type": "${PHEE_PAYEE_ID_TYPE}",
            # payee_id_type_to_send left unset (False): _get_dfsp_id_and_type() only
            # falls back to its "PHONE" default for payee_id_type=phone when this is
            # falsy. The model's OWN field default is "ACCOUNT_ID", which — if left
            # in place — silently overrides the phone default and sends the wrong
            # identifier type to Mojaloop even though payee_id_type=phone. Verified:
            # leaving this set produced payee_identifier_type=ACCOUNT_ID with no
            # matching account, clearing it produced the correct PHONE type.
            "payee_id_type_to_send": False,
            "batch_type_header": "csv",
            # Without this, prepare_payment() creates g2p.payment records but never
            # wraps them in a g2p.payment.batch, so cycle.payment_batch_ids stays
            # empty and "Send Payments" silently loops over zero batches (no error,
            # no HTTP call, no visible effect). Verified against a live cycle.
            "create_batch": True,
        })
        env.cr.commit()
        print("PHEE_MGR_CREATED", phee.id)
    ref = "g2p.program.payment.manager.phee,%d" % phee.id
    w = Wire.search([("program_id", "=", prog.id), ("manager_ref_id", "=", ref)], limit=1)
    if not w:
        w = Wire.create({"program_id": prog.id, "manager_ref_id": ref})
        env.cr.commit()
        print("WIRE_CREATED", w.id)
    else:
        print("WIRE_EXISTS", w.id)
    # The program's payment_managers is a Many2many constrained to exactly ONE entry,
    # and it is what get_manager(MANAGER_PAYMENT) reads when issuing a batch. The wizard
    # put a *default* payment manager there; REPLACE it with the PHEE wire so batches
    # actually go to Payment Hub EE. Creating the wire above is not enough on its own —
    # the M2M link must be set explicitly.
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
# Description: Step 5 — funds the demo program (g2p.program.fund) so it has a
#              funding pool to pay entitlements from. Idempotent: skips if a
#              POSTED fund already exists for this program (cancelled/draft funds
#              don't count — a posted fund can't be deleted per
#              fund_management.py's _unlink_fund, so cancelling is the only way
#              to retire one). The exact amount can be tuned by editing
#              PROGRAM_FUND_AMOUNT and re-running after cancelling the old fund
#              in the UI — this step does not resize existing funds.
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
# Description: POSTs one FSPIOP participant association from inside the cluster,
#              via a short-lived curl pod, to register an MSISDN->fspId mapping
#              in the vNext ALS oracle (used by sync_vnext_oracle). The delete of
#              the one-shot pod is best-effort and synchronous so no orphaned
#              pods are left behind if the caller exits early.
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
# Description: Read-only check that an MSISDN->fspId association actually
#              persisted in the Mongo builtin oracle (verification only — all
#              writes go through the FSPIOP API in _fspiop_register_party).
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
# Description: Step 6 — registers every mirrored client in the vNext ALS oracle
#              so it resolves at transfer-time party lookup. Uses the supported
#              FSPIOP participant-registration API on fspiop-api-svc (POST
#              /participants/MSISDN/<msisdn>), which publishes a Kafka
#              association event that account-lookup-svc persists into the
#              Mongo builtin oracle (account-lookup.builtinOracleParties) — the
#              store the switch actually reads. No direct DB writes. The POST is
#              idempotent (re-POST of an existing party is a no-op). fspId = the
#              client's Fineract tenant (bluebank). Payer MSISDNs are excluded
#              (never payees). Non-fatal — a hiccup only means some payees won't
#              route, it never aborts the PBMS setup.
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

  local registered=0 verified=0 failed=0
  # Read the TSV on FD 3, not stdin: the kubectl exec -i / kubectl calls in the loop
  # body would otherwise consume the loop's stdin and truncate it to one iteration.
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

    # The association is processed asynchronously off Kafka — poll Mongo (read-only)
    # until it shows up, so we report real persistence rather than just the 202.
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

  # Dependencies must be running alongside OpenG2P — abort early with a clear
  # message if mifosx / paymenthub / vnext isn't up (see preflight_dependencies).
  preflight_dependencies || exit 1

  local pod
  pod="$(_find_pbms_pod)"
  if [[ -z "$pod" ]]; then
    log_error "no Running pbms-odoo pod in namespace '$NS' — deploy PBMS first (./run.sh -m deploy -a openg2p)"
    exit 1
  fi
  log_with_level "$INFO" "Using pod: $pod"
  log_with_level "$INFO" "Reading clients from Fineract at ${FINERACT_BASE}"

  # Resolve the demo payer MSISDN from Fineract (never hardcoded — see
  # resolve_payer_msisdn / PHEE_PAYER_TENANT). It drives BOTH the registry exclude
  # list (the payer is not a beneficiary) and the PHEE payment manager's payer_id.
  log_step "Resolving payer MSISDN from Fineract tenant '${PHEE_PAYER_TENANT}'"
  PHEE_PAYER_ID="$(resolve_payer_msisdn)"
  if [[ -z "$PHEE_PAYER_ID" ]]; then
    log_warn "no client with a mobile number found in tenant '${PHEE_PAYER_TENANT}' — payer will not be excluded/wired (is MifosX seeded?)"
  else
    EXCLUDE_MSISDNS=("$PHEE_PAYER_ID")
    log_ok
    log_with_level "$INFO" "Payer: ${PHEE_PAYER_TENANT} MSISDN ${PHEE_PAYER_ID}"
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
