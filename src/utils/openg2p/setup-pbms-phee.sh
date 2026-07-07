#!/usr/bin/env bash
#------------------------------------------------------------------------------
# setup-pbms-phee.sh -- enable the OpenG2P g2p_payment_phee connector on a running
# Gazelle PBMS (Odoo) so PBMS can issue payment batches to Payment Hub EE.
#
# Runs a sequence of idempotent steps against the live cluster, driven via
# `kubectl exec ... odoo shell` on the running pbms-odoo pod. Called from
# openg2p.sh after PBMS deploys; safe to re-run. Failures log a WARN and continue.
#
# Steps (see the step_* functions below for detail):
#   1   Download the addon repos as tarballs into the PVC and point Odoo
#       at them via ODOO_ADDONS_DIR (set in openg2p-pbms/values.yaml).
#   1b  Confirm ODOO_ADDONS_DIR points at the downloaded repos.
#   2   Cast amount_issued to int in payment_manager.py (PHEE's parseInt throws on
#       the float, silently zeroing the batch total). Patched before the install so
#       the single post-install restart reloads the patched source too.
#   3   Stub the Enterprise-only base.module_payment_sepa_direct_debit xmlid that
#       g2p_programs references but Community lacks (else install crashes), then
#       install PBMS_MODULES.
#   4   Set batch_type_header=csv on the PHEE payment manager (default "type" makes
#       PHEE 500).
#------------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONFIG_FILE="${RUN_DIR}/config/config.ini"

# shellcheck source=/dev/null
source "${RUN_DIR}/src/utils/logger.sh"

# --- addon sources (step 1) — repo:branch, fetched as <branch>.tar.gz from GitHub ---
ADDON_REPOS=(
  "openg2p-registry:17.0-1.5"
  "openg2p-program:17.0-1.3"
)
ADDONS_DIR="/bitnami/odoo/extraaddons"
# Modules to install (the rest are baked into the image). Installing g2p_payment_phee
# pulls the full g2p_programs tree transitively (slow). pbms_theme_extension is
# deliberately excluded — it depends on `website` and 500s the Community login page.
PBMS_MODULES=(g2p_social_registry_importer g2p_payment_phee)
# The float->int patch target inside the downloaded addon (step 2).
PHEE_PM_FILE="${ADDONS_DIR}/openg2p-program/g2p_payment_phee/models/payment_manager.py"
ODOO_DB="pbmsdb"
# Gazelle helm release is `pbms`, so the odoo Deployment is `pbms-odoo`.
ODOO_DEPLOY="pbms-odoo"

OPENG2P_NAMESPACE="$(crudini --get "$CONFIG_FILE" openg2p OPENG2P_NAMESPACE 2>/dev/null || echo openg2p)"
NS="$OPENG2P_NAMESPACE"

# Verbose flag for log_with_verbose_check. openg2p.sh runs us in a fresh subshell
# (bash setup-pbms-phee.sh) and does not export `debug`, so it is always unset here;
# under `set -u` an unbound "$debug" would abort. Default it so the script runs.
debug="${debug:-false}"

#------------------------------------------------------------------------------
# Helpers
#------------------------------------------------------------------------------
_find_pbms_pod() {
  kubectl get pods -n "$NS" --no-headers 2>/dev/null \
    | awk '/^pbms-odoo-/ && $3=="Running"{print $1; exit}'
}

# Pipe a python heredoc (on stdin) into `odoo shell` in the pod, succeeding only
# when $2 (sentinel) is printed. $1 = pod. Mirrors _openg2p_pbms_fix_admin_login.
_odoo_shell() {
  local pod="$1" sentinel="$2"
  kubectl exec -i -n "$NS" "$pod" -- \
    bash -lc "odoo shell -c /etc/odoo/odoo.conf -d '$ODOO_DB' --no-http 2>/dev/null" \
    | grep -q "$sentinel"
}

_restart_odoo() {
  log_step "Restarting $ODOO_DEPLOY to reload modules/source"
  if kubectl rollout restart "deploy/$ODOO_DEPLOY" -n "$NS" >/dev/null 2>&1 \
     && kubectl rollout status "deploy/$ODOO_DEPLOY" -n "$NS" --timeout=300s >/dev/null 2>&1; then
    log_ok
  else
    log_warn "rollout of $ODOO_DEPLOY did not complete — restart it manually so new modules/source load"
  fi
}

# The bg-task deployments write ir_module_module periodically; a concurrent write during
# a module install triggers Postgres "could not serialize access" and aborts it. Scale
# them to 0 for the install, back up after.
BGTASK_DEPLOYS=(pbms-api pbms-celery-beat-producer pbms-celery-worker)
_bgtask_scale() {
  local replicas="$1"
  kubectl scale deploy "${BGTASK_DEPLOYS[@]}" -n "$NS" --replicas="$replicas" >/dev/null 2>&1
}

# The addon repos' Python deps (schwifty, rstr, cbor2, ...) install into ephemeral
# /usr/local/lib, so a freshly-rolled odoo pod is missing them until the values.yaml
# postStart hook runs. Skip fast when the hook already installed them (import check),
# else install so this works on a pre-redeploy pod without the hook.
_pip_install_addon_deps() {
  local pod="$1"
  if kubectl exec -n "$NS" "$pod" -- python3 -c 'import schwifty, rstr' >/dev/null 2>&1; then
    log_with_verbose_check "$debug" "$DEBUG" "addon Python deps already present — skipping pip install"
    return 0
  fi
  log_step "Installing addon Python deps (schwifty, rstr, ...)"
  kubectl exec -n "$NS" "$pod" -- bash -lc '
    unset SSL_CERT_FILE REQUESTS_CA_BUNDLE
    pip install -q --trusted-host pypi.org --trusted-host files.pythonhosted.org \
      -r /bitnami/odoo/extraaddons/openg2p-registry/requirements.txt \
      -r /bitnami/odoo/extraaddons/openg2p-program/requirements.txt rstr' >/dev/null 2>&1 \
    && log_ok || log_warn "addon dep pip-install failed — check pod network egress"
}

#------------------------------------------------------------------------------
# Step 1 — download addon repos into the PVC. Idempotent: skips a repo that
# already has content. curl+tar because the image has no git.
#------------------------------------------------------------------------------
step_download_addons() {
  local pod="$1" entry repo branch url
  for entry in "${ADDON_REPOS[@]}"; do
    repo="${entry%%:*}"
    branch="${entry##*:}"
    url="https://github.com/OpenG2P/${repo}/archive/refs/heads/${branch}.tar.gz"
    log_step "Fetching addon repo ${repo}@${branch}"
    kubectl exec -n "$NS" "$pod" -- bash -c "
      set -e
      mkdir -p '${ADDONS_DIR}'
      dest='${ADDONS_DIR}/${repo}'
      if [ -d \"\$dest\" ] && [ \"\$(ls -A \"\$dest\" 2>/dev/null | wc -l)\" -gt 5 ]; then
        echo ADDON_PRESENT; exit 0
      fi
      mkdir -p \"\$dest\"
      curl -sSL '${url}' -o /tmp/${repo}.tgz
      tar xzf /tmp/${repo}.tgz -C \"\$dest\" --strip-components=1
      rm -f /tmp/${repo}.tgz
      echo ADDON_FETCHED
    " >/dev/null 2>&1 \
      && log_ok \
      || log_warn "could not fetch ${repo}@${branch} into ${ADDONS_DIR} (check pod network egress)"
  done
}

#------------------------------------------------------------------------------
# Step 1b — confirm Odoo is pointed at the addon dirs (ODOO_ADDONS_DIR is set in
# values.yaml; here we only check, since a live env edit would be reverted on upgrade).
#------------------------------------------------------------------------------
step_check_addons_dir() {
  local pod="$1" env_val
  log_step "Checking ODOO_ADDONS_DIR includes the addon repos"
  env_val="$(kubectl exec -n "$NS" "$pod" -- bash -lc 'echo "${ODOO_ADDONS_DIR:-}"' 2>/dev/null)"
  if [[ "$env_val" == *"${ADDONS_DIR}/openg2p-program"* ]]; then
    log_ok
  else
    log_warn "ODOO_ADDONS_DIR does not include ${ADDONS_DIR}/openg2p-* (got: '${env_val:-<unset>}')."
    log_warn "  Add it to src/deployer/helm/openg2p/openg2p-pbms/values.yaml (odoo.extraEnvVars) and redeploy:"
    log_warn "    ./run.sh -m deploy -a openg2p"
  fi
}

#------------------------------------------------------------------------------
# Step 3 — enterprise stub + module install. Refreshes the module list, stubs the
# missing xmlid, then installs PBMS_MODULES. Idempotent (skips installed).
#------------------------------------------------------------------------------
step_stub_and_install() {
  local pod="$1"
  # Eliminate DB write contention for the duration of the install (see _bgtask_scale).
  log_step "Scaling down PBMS bg-task during install"
  _bgtask_scale 0 && log_ok || log_warn "could not scale bg-task down — install may hit serialization errors"
  log_step "Stubbing enterprise xmlid + installing PBMS modules (slow: ~10-15m)"
  # MODULES python list is built from PBMS_MODULES: first element quoted, then
  # ', "elem"' for the rest — yields ["a", "b", ...] inside the heredoc.
  _odoo_shell "$pod" PHEE_MODULES_OK <<PYEOF
try:
    env.ref("base.module_payment_sepa_direct_debit")
except Exception:
    stub = env["ir.module.module"].search([("name","=","payment_sepa_direct_debit")], limit=1)
    if not stub:
        stub = env["ir.module.module"].create({
            "name": "payment_sepa_direct_debit",
            "state": "uninstalled",
            "shortdesc": "SEPA Direct Debit (stub for Community)",
        })
    if not env["ir.model.data"].search([("module","=","base"),("name","=","module_payment_sepa_direct_debit")], limit=1):
        env["ir.model.data"].create({
            "module": "base",
            "name": "module_payment_sepa_direct_debit",
            "model": "ir.module.module",
            "res_id": stub.id,
            "noupdate": True,
        })
    env.cr.commit()
env["ir.module.module"].update_list()
env.cr.commit()
MODULES = ["${PBMS_MODULES[0]}"$(printf ', "%s"' "${PBMS_MODULES[@]:1}")]
for name in MODULES:
    m = env["ir.module.module"].search([("name","=",name)], limit=1)
    if not m:
        print("MISSING_MODULE", name)
        continue
    if m.state in ("installed", "to upgrade", "to install"):
        continue
    m.button_immediate_install()
    env.cr.commit()
print("PHEE_MODULES_OK")
PYEOF
  if [[ $? -eq 0 ]]; then log_ok; else log_warn "module install did not complete — check odoo logs on $pod, then re-run"; fi
  # Web workers hold a stale registry after install; restart so new models load.
  _restart_odoo
  # Ensure the addon deps are on the new pod (postStart usually does this; belt-and-suspenders).
  pod="$(_find_pbms_pod)"; [[ -n "$pod" ]] || { log_error "pbms-odoo pod gone after restart"; return 1; }
  _pip_install_addon_deps "$pod"
  # Restore bg-task now that the heavy install is done.
  log_step "Scaling PBMS bg-task back up"
  _bgtask_scale 1 && log_ok || log_warn "could not scale bg-task back up — run: kubectl scale deploy ${BGTASK_DEPLOYS[*]} -n $NS --replicas=1"
}

#------------------------------------------------------------------------------
# Step 4 — batch_type_header=csv on the PHEE payment manager(s). Default "type"
# makes PHEE 500. Also aligns payee_id_type to phone (proven default). Idempotent.
# Managers may not exist yet (created via UI) — that's fine.
#------------------------------------------------------------------------------
step_batch_header() {
  local pod="$1"
  log_step "Setting batch_type_header=csv on PHEE payment manager(s)"
  _odoo_shell "$pod" PHEE_HEADER_OK <<'PYEOF'
Mgr = env.get('g2p.program.payment.manager.phee')
n = 0
if Mgr is not None:
    for m in Mgr.sudo().search([]):
        changed = False
        if 'batch_type_header' in m._fields and m.batch_type_header != 'csv':
            m.batch_type_header = 'csv'; changed = True
        if 'payee_id_type' in m._fields and m.payee_id_type != 'phone':
            m.payee_id_type = 'phone'; changed = True
        if changed:
            n += 1
    env.cr.commit()
print('PHEE_HEADER_OK', n)
PYEOF
  if [[ $? -eq 0 ]]; then log_ok; else log_warn "could not set batch_type_header — set it on the PHEE payment manager manually (must be 'csv')"; fi
}

#------------------------------------------------------------------------------
# Step 2 — float->int amount patch: wrap the CSV-row payment_id.amount_issued in
# int(). Idempotent. Runs BEFORE the install (step 3) so the single post-install
# restart reloads the patched source too — the downloaded file already exists from
# step 1.
#------------------------------------------------------------------------------
step_patch_amount() {
  local pod="$1"
  log_step "Patching amount_issued float->int in payment_manager.py"
  kubectl exec -n "$NS" "$pod" -- bash -c "
    set -e
    f='${PHEE_PM_FILE}'
    [ -f \"\$f\" ] || { echo NO_FILE; exit 3; }
    if grep -q 'int(payment_id.amount_issued)' \"\$f\"; then echo ALREADY_PATCHED; exit 0; fi
    # Only the standalone CSV-row emission line (trailing comma), not the
    # 'amount_issued': entitlement_id.initial_amount dict assignment elsewhere.
    sed -i -E 's/^([[:space:]]*)payment_id\.amount_issued,[[:space:]]*\$/\1int(payment_id.amount_issued),/' \"\$f\"
    grep -q 'int(payment_id.amount_issued)' \"\$f\" && echo PATCHED || { echo PATCH_FAILED; exit 4; }
  " >/dev/null 2>&1
  local rc=$?
  if [[ $rc -eq 0 ]]; then log_ok
  else log_warn "amount_issued patch not applied (rc=$rc) — edit ${PHEE_PM_FILE} manually (wrap the CSV-row amount in int())"; fi
}

#------------------------------------------------------------------------------
# main
#------------------------------------------------------------------------------
main() {
  log_section "Enabling g2p_payment_phee on PBMS (namespace: $NS)"

  command -v kubectl  >/dev/null 2>&1 || { log_error "kubectl not found on PATH"; exit 1; }
  command -v crudini  >/dev/null 2>&1 || { log_error "crudini not found on PATH"; exit 1; }

  local pod
  pod="$(_find_pbms_pod)"
  if [[ -z "$pod" ]]; then
    log_error "no Running pbms-odoo pod in namespace '$NS' — deploy PBMS first (./run.sh -m deploy -a openg2p)"
    exit 1
  fi
  log_with_level "$INFO" "Using pod: $pod"

  step_download_addons  "$pod"
  step_check_addons_dir "$pod"
  # Patch before installing, so the single post-install restart reloads the patched
  # source too — avoids a second pod rollout and pip reinstall.
  step_patch_amount     "$pod"
  step_stub_and_install "$pod"
  # re-resolve the pod: the module-install restart rolls a new pod
  pod="$(_find_pbms_pod)"; [[ -n "$pod" ]] || { log_error "pbms-odoo pod gone after restart"; exit 1; }
  step_batch_header     "$pod"

  log_step "Verifying /web/login serves (200)"
  local code
  code="$(kubectl exec -n "$NS" "$pod" -- bash -lc 'curl -s -o /dev/null -w "%{http_code}" http://localhost:8069/web/login' 2>/dev/null)"
  if [[ "$code" == "200" ]]; then log_ok; else log_warn "login returned HTTP $code — check: kubectl logs -n $NS $pod | grep -i error"; fi

  log_banner "g2p_payment_phee setup complete"
  log_with_level "$INFO" "Verify: kubectl exec -n $NS \$(kubectl get po -n $NS -o name | grep pbms-odoo | head -1) -- ls $ADDONS_DIR"
  log_with_level "$INFO" "Then trigger a PBMS->PHEE batch and confirm total > 0 (no fileName/NumberFormat errors)."
}

main "$@"
