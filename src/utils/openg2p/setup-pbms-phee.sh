#!/usr/bin/env bash
# setup-pbms-phee.sh -- activates the OpenG2P Odoo modules on a running PBMS and
# wires the g2p_payment_phee connector so PBMS can issue batches to Payment Hub EE.
# Called from openg2p.sh after PBMS deploys; safe to re-run. Failures WARN and continue.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONFIG_FILE="${RUN_DIR}/config/config.ini"

# shellcheck source=/dev/null
source "${RUN_DIR}/src/utils/logger.sh"

# Addon repos fetched as <branch>.tar.gz from GitHub (step 1).
ADDON_REPOS=(
  "openg2p-registry:17.0-1.5"
  "openg2p-program:17.0-1.3"
)
ADDONS_DIR="/bitnami/odoo/extraaddons"
# Modules to install. g2p_theme last so the payment path is installed first.
PBMS_MODULES=(g2p_social_registry_importer g2p_programs g2p_payment_phee g2p_theme)
PHEE_MODULE_DIR="${ADDONS_DIR}/openg2p-program/g2p_payment_phee"
# Host-side tarball cache. Outlives a redeploy (which recreates the pod's volume), so
# GitHub is asked once per repo per machine rather than once per deploy.
ADDON_CACHE_DIR="${TMPDIR:-/tmp}/gazelle-openg2p-addons"
PHEE_PM_FILE="${PHEE_MODULE_DIR}/models/payment_manager.py"
ODOO_DB="pbmsdb"
ODOO_DEPLOY="pbms-odoo"

# Marker that guards the callback-reconciliation block appended to the upstream
# payment manager, so every patch step below is safe to re-run.
PHEE_CB_MARKER="GAZELLE-PHEE-CALLBACK"
# Payment Hub's operations API, read back during reconciliation. In-cluster, so no
# ingress and no TLS: the ingress hostname would need the self-signed cert trusted.
PHEE_OPS_API_URL="http://ph-ee-operations-app.paymenthub:80/api/v1/batch"

OPENG2P_NAMESPACE="$(crudini --get "$CONFIG_FILE" openg2p OPENG2P_NAMESPACE 2>/dev/null || echo openg2p)"
NS="$OPENG2P_NAMESPACE"

# Where Payment Hub is told to post batch progress. It runs in another namespace, so this
# is the PBMS Service's cluster DNS name; port 80 is the Service port in front of Odoo.
PHEE_CB_BASE_URL="http://pbms-odoo.${NS}.svc.cluster.local"

# openg2p.sh runs us in a subshell without exporting `debug` — default it for set -u.
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
# Function : _odoo_shell_verbose
# Description: As _odoo_shell, but keeps stderr and prints the output tail when the
#              sentinel is missing. Used for the module install.
# Parameters:
#   $1 - pod name

#   $2 - sentinel string the heredoc must print for success
# Returns: 0 only if the sentinel appears.
#------------------------------------------------------------------------------
_odoo_shell_verbose() {
  local pod="$1" sentinel="$2" out
  out="$(kubectl exec -i -n "$NS" "$pod" -- \
    bash -lc "odoo shell -c /etc/odoo/odoo.conf -d '$ODOO_DB' --no-http" 2>&1)"
  if echo "$out" | grep -q "$sentinel"; then
    return 0
  fi
  log_warn "odoo shell output (last 20 lines):"
  echo "$out" | tail -20 >&2
  return 1
}

#------------------------------------------------------------------------------
# Function : _restart_odoo
# Description: Rolls the pbms-odoo Deployment so new modules / patched source are
#              reloaded. Non-fatal.
#------------------------------------------------------------------------------
_restart_odoo() {
  log_step "Restarting $ODOO_DEPLOY to reload modules/source"
  if kubectl rollout restart "deploy/$ODOO_DEPLOY" -n "$NS" >/dev/null 2>&1 \
     && kubectl rollout status "deploy/$ODOO_DEPLOY" -n "$NS" --timeout=300s >/dev/null 2>&1; then
    log_ok
  else
    log_warn "rollout of $ODOO_DEPLOY did not complete — restart it manually so new modules/source load"
  fi
}

#------------------------------------------------------------------------------
# Function : _registry_healthy
# Description: Checks the pod's Odoo registry is not stale. A module can install
#              after the workers cached their registry, which 500s the Registry
#              pages while /web/login still answers 200.
# Parameters:
#   $1 - pod name
# Returns: 0 if res.partner is reachable, 1 otherwise.
#------------------------------------------------------------------------------
_registry_healthy() {
  local pod="$1"
  kubectl exec -i -n "$NS" "$pod" -- \
    bash -lc "odoo shell -c /etc/odoo/odoo.conf -d '$ODOO_DB' --no-http 2>/dev/null" \
    <<'PYEOF' 2>/dev/null | grep -q REGISTRY_HEALTHY
try:
    env["res.partner"].sudo().search_count([("is_registrant", "=", True)])
    print("REGISTRY_HEALTHY")
except Exception as e:
    print("REGISTRY_BROKEN", type(e).__name__, str(e)[:120])
PYEOF
}

BGTASK_DEPLOYS=(pbms-api pbms-celery-beat-producer pbms-celery-worker)

#------------------------------------------------------------------------------
# Function : _bgtask_scale
# Description: Scales the PBMS bg-task deployments. Their periodic
#              ir_module_module writes trip Postgres "could not serialize access"
#              during a module install, so they go to 0 for it.
# Parameters:
#   $1 - replica count
#------------------------------------------------------------------------------
_bgtask_scale() {
  local replicas="$1"
  kubectl scale deploy "${BGTASK_DEPLOYS[@]}" -n "$NS" --replicas="$replicas" >/dev/null 2>&1
}

#------------------------------------------------------------------------------
# Function : _pip_install_addon_deps
# Description: Installs the addon repos' Python deps into the running pod. They land
#              in ephemeral /usr/local/lib, so a rolled pod lacks them until the
#              values.yaml postStart hook runs. Skips fast if present. Non-fatal.
# Parameters:
#   $1 - pod name
#------------------------------------------------------------------------------
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
# Function : _addon_unpacked
# Description: True when a repo already looks unpacked in the pod's addons dir. The
#              ">5 entries" test tolerates the empty directory the chart's postStart
#              hook creates, which exists before anything has been fetched.
# Parameters:
#   $1 - pod name
#   $2 - repo directory name
#------------------------------------------------------------------------------
_addon_unpacked() {
  local pod="$1" repo="$2"
  kubectl exec -n "$NS" "$pod" -- bash -c \
    "[ \"\$(ls -A '${ADDONS_DIR}/${repo}' 2>/dev/null | wc -l)\" -gt 5 ]" >/dev/null 2>&1
}

#------------------------------------------------------------------------------
# Function : step_download_addons
# Description: Step 1 — puts the addon repos in the pod's addons dir. Uses curl+tar
#              because the image has no git. Idempotent.
#
#              Downloaded on the HOST into a cache that survives redeploys, then copied
#              in. The pod's volume is recreated by a redeploy, so fetching from inside
#              the pod asked GitHub for both tarballs on every single deploy, and
#              codeload.github.com throttles anonymous tarball pulls per IP hard enough
#              to break that: measured from this network, roughly one request in five
#              succeeded and the rest answered 429 or 503. The cache means GitHub is
#              asked once per repo per machine instead of once per deploy.
# Parameters:
#   $1 - pod name
#------------------------------------------------------------------------------
step_download_addons() {
  local pod="$1" entry repo branch url tgz attempt
  mkdir -p "$ADDON_CACHE_DIR"
  for entry in "${ADDON_REPOS[@]}"; do
    repo="${entry%%:*}"
    branch="${entry##*:}"
    url="https://github.com/OpenG2P/${repo}/archive/refs/heads/${branch}.tar.gz"
    tgz="${ADDON_CACHE_DIR}/${repo}-${branch}.tar.gz"
    log_step "Fetching addon repo ${repo}@${branch}"

    if _addon_unpacked "$pod" "$repo"; then
      log_ok
      log_with_verbose_check "$debug" "$DEBUG" "${repo} already unpacked in ${ADDONS_DIR}"
      continue
    fi

    if [[ -s "$tgz" ]]; then
      log_with_verbose_check "$debug" "$DEBUG" "using cached tarball ${tgz}"
    else
      # -f so a 429 or 503 body is never saved as though it were the archive: without it
      # curl exits 0, writes the error page, and tar then dies with "not in gzip format".
      # tar -t confirms the download really is an archive before it is cached. Backoff
      # because the throttle rejects most requests in a burst.
      for attempt in 1 2 3 4 5 6; do
        [[ $attempt -gt 1 ]] && sleep $((attempt * 3))
        if curl -fsSL "$url" -o "${tgz}.part" 2>/dev/null \
           && tar tzf "${tgz}.part" >/dev/null 2>&1; then
          mv -f "${tgz}.part" "$tgz"
          log_with_verbose_check "$debug" "$DEBUG" "downloaded ${repo}@${branch} on attempt ${attempt}"
          break
        fi
        rm -f "${tgz}.part"
      done
    fi

    if [[ ! -s "$tgz" ]]; then
      log_warn "could not download ${repo}@${branch} after 6 attempts — GitHub throttles anonymous"
      log_warn "  tarball pulls per IP (429/503). Re-run later, or drop the tarball at:"
      log_warn "    ${tgz}"
      continue
    fi

    # Unpacked into a staging dir and swapped in, so a failure part-way never replaces a
    # working tree with a partial one — which _addon_unpacked would then accept as fine.
    if kubectl cp "$tgz" "${NS}/${pod}:/tmp/${repo}.tgz" >/dev/null 2>&1 \
       && kubectl exec -n "$NS" "$pod" -- bash -c "
            set -e
            mkdir -p '${ADDONS_DIR}'
            rm -rf '${ADDONS_DIR}'/.stage-* 2>/dev/null || true
            stage=\$(mktemp -d '${ADDONS_DIR}/.stage-XXXXXX')
            tar xzf '/tmp/${repo}.tgz' -C \"\$stage\" --strip-components=1
            rm -rf '${ADDONS_DIR}/${repo}'
            mv \"\$stage\" '${ADDONS_DIR}/${repo}'
            rm -f '/tmp/${repo}.tgz'
          " >/dev/null 2>&1; then
      log_ok
    else
      log_warn "could not unpack ${repo}@${branch} into ${ADDONS_DIR} on ${pod}"
    fi
  done
}

#------------------------------------------------------------------------------
# Function : step_check_addons_dir
# Description: Step 1b — confirms Odoo is pointed at the addon dirs. ODOO_ADDONS_DIR
#              is set in values.yaml, so this only checks and warns with the fix.
# Parameters:
#   $1 - pod name
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
# Function : step_stub_and_install
# Description: Step 3 — stubs the Enterprise-only xmlid g2p_programs needs (else
#              the install crashes), installs PBMS_MODULES with bg-task scaled to 0,
#              then restarts Odoo. Idempotent.
# Parameters:
#   $1 - pod name
#------------------------------------------------------------------------------
step_stub_and_install() {
  local pod="$1"
  # Deps must exist BEFORE button_immediate_install() — the modules import them at
  # load time, and postStart installed nothing when the addon dirs were still empty.
  _pip_install_addon_deps "$pod"
  log_step "Scaling down PBMS bg-task during install"
  _bgtask_scale 0 && log_ok || log_warn "could not scale bg-task down — install may hit serialization errors"
  log_step "Stubbing enterprise xmlid + installing PBMS modules (slow: ~10-15m)"
  local install_py
  install_py="$(cat <<PYEOF
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
)"
  # A first exec against a just-Ready pod can fail with a bare exit 1 while an
  # identical call moments later succeeds. Safe to repeat (installed modules skip).
  local install_attempt install_ok=false
  for install_attempt in 1 2 3; do
    if [[ "$install_attempt" -gt 1 ]]; then
      log_warn "module install attempt $((install_attempt - 1)) failed — retrying ($install_attempt/3) in 15s"
      sleep 15
    fi
    if echo "$install_py" | _odoo_shell_verbose "$pod" PHEE_MODULES_OK; then
      install_ok=true
      break
    fi
  done
  if [[ "$install_ok" == true ]]; then log_ok; else log_warn "module install did not complete after 3 attempts — check odoo logs on $pod, then re-run"; fi
  # Web workers hold a stale registry after install; restart so new models load.
  _restart_odoo
  pod="$(_find_pbms_pod)"; [[ -n "$pod" ]] || { log_error "pbms-odoo pod gone after restart"; return 1; }
  log_step "Verifying registry is not stale (res.partner reachable)"
  if _registry_healthy "$pod"; then
    log_ok
  else
    log_warn "registry still stale after restart — retrying restart once"
    _restart_odoo
    pod="$(_find_pbms_pod)"; [[ -n "$pod" ]] || { log_error "pbms-odoo pod gone after retry restart"; return 1; }
    log_step "Re-verifying registry is not stale"
    if _registry_healthy "$pod"; then
      log_ok
    else
      log_warn "registry still stale after a second restart — run manually: kubectl rollout restart deploy/$ODOO_DEPLOY -n $NS"
    fi
  fi
  # postStart on the new pod can race pod-Ready, so ensure the deps here too.
  _pip_install_addon_deps "$pod"
  log_step "Scaling PBMS bg-task back up"
  _bgtask_scale 1 && log_ok || log_warn "could not scale bg-task back up — run: kubectl scale deploy ${BGTASK_DEPLOYS[*]} -n $NS --replicas=1"
}

#------------------------------------------------------------------------------
# Function : step_batch_header
# Description: Step 4 — sets batch_type_header=csv on the PHEE payment manager(s)
#              (the default "type" makes PHEE 500) and payee_id_type to phone.
# Parameters:
#   $1 - pod name
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
# Function : step_patch_amount
# Description: Step 2 — wraps the CSV-row amount_issued in int(); PHEE's parseInt
#              throws on the float and silently zeroes the batch total.
# Parameters:
#   $1 - pod name
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

# Set by _write_pod_file when it actually changed a file. Odoo imports a controller at
# process start, so changed source means the pod has to be rolled before the new route
# is served; without this a re-run that edits the controller would silently keep serving
# the old one, because the upgrade step skips once the fields are already there.
PHEE_CB_SOURCE_CHANGED=false

#------------------------------------------------------------------------------
# Function : _write_pod_file
# Description: Writes stdin to a path in the pod, creating parent dirs. Used to add the
#              callback files to the upstream module tree. Writes via a temp file and
#              only replaces the target when the content differs, so a re-run that
#              changes nothing does not force a restart.
# Parameters:
#   $1 - pod name
#   $2 - absolute destination path in the pod
# Returns: 0 on success. Sets PHEE_CB_SOURCE_CHANGED=true when the file changed.
#------------------------------------------------------------------------------
_write_pod_file() {
  local pod="$1" dest="$2" out
  out="$(kubectl exec -i -n "$NS" "$pod" -- bash -c "
    set -e
    dest='$dest'
    mkdir -p \"\$(dirname \"\$dest\")\"
    tmp=\"\$dest.gazelle-new\"
    cat > \"\$tmp\"
    if [ -f \"\$dest\" ] && cmp -s \"\$tmp\" \"\$dest\"; then
      rm -f \"\$tmp\"; echo FILE_SAME
    else
      mv \"\$tmp\" \"\$dest\"; echo FILE_REPLACED
    fi
  ")" || return 1
  # Matched exactly: a substring test would also fire on the unchanged token.
  if [[ "$out" == *FILE_REPLACED* ]]; then
    PHEE_CB_SOURCE_CHANGED=true
  fi
  return 0
}

#------------------------------------------------------------------------------
# Function : step_callback_controller
# Description: Step 5a — adds the HTTP endpoint Payment Hub posts batch progress to.
#              Upstream g2p_payment_phee has no controllers package, so this is a new
#              file rather than a patch. Rewritten every run: it is ours, not theirs.
# Parameters:
#   $1 - pod name
#------------------------------------------------------------------------------
step_callback_controller() {
  local pod="$1" rc=0
  log_step "Adding the PHEE batch-progress callback controller"
  _write_pod_file "$pod" "${PHEE_MODULE_DIR}/controllers/__init__.py" <<'PYEOF' || rc=1
# Added by Gazelle (src/utils/openg2p/setup-pbms-phee.sh). Not upstream OpenG2P.
from . import phee_callback
PYEOF
  _write_pod_file "$pod" "${PHEE_MODULE_DIR}/controllers/phee_callback.py" <<'PYEOF2' || rc=1
# Added by Gazelle (src/utils/openg2p/setup-pbms-phee.sh). Not upstream OpenG2P.
"""Receives Payment Hub EE's batch progress callback.

Payment Hub posts to whatever URL it was given in the X-CallbackURL header of the
/batchtransactions upload, with a body of:

    {"clientCorrelationId": "<zeebe key>",
     "batchId": "<Payment Hub's own batch id>",
     "message": "The Batch Aggregation API was complete with : 75"}

Neither id in that body is the X-CorrelationID PBMS sent, so the batch is identified
by the reference carried in the URL path instead. The body's batchId is kept: that,
not our correlation id, is what the operations API is queried with.
"""
import json
import logging

from odoo import http
from odoo.http import request

_logger = logging.getLogger(__name__)


class PheeCallbackController(http.Controller):
    """The one route Payment Hub calls back on.

    auth='none' because Payment Hub cannot authenticate: it is handed a URL and
    nothing else, and adds no headers of its own. Two things stand in for a
    credential - the per-manager token in the path, and the batch reference, which
    is an unguessable uuid4 that has to already exist and have been sent.
    """

    def _json(self, payload, status=200):
        return request.make_response(
            json.dumps(payload),
            headers=[("Content-Type", "application/json")],
            status=status,
        )

    @http.route(
        "/g2p/phee/callback/<string:token>/<string:batch_ref>",
        type="http",
        auth="none",
        methods=["POST"],
        csrf=False,
        save_session=False,
    )
    def phee_batch_callback(self, token, batch_ref, **kwargs):
        # sudo() throughout: the route is auth='none', so request.env is the public
        # user, which can read neither the payment batches nor the manager holding
        # the token. The path token and the batch reference are the gate.
        # nosemgrep: odoo-sudo-without-context
        batch = (
            request.env["g2p.payment.batch"]
            .sudo()
            .search(
                [
                    ("external_batch_ref", "=", batch_ref),
                    ("batch_has_started", "=", True),
                ],
                limit=1,
            )
        )
        if not batch:
            # 404 rather than 401: an unknown reference is indistinguishable from a
            # batch this PBMS never sent, and saying which would leak whether it exists.
            _logger.warning("PHEE callback for unknown batch reference %s", batch_ref)
            return self._json({"status": "unknown batch"}, status=404)

        program = batch.cycle_id.program_id
        try:
            manager = program.get_manager(program.MANAGER_PAYMENT) if program else None
        except Exception:
            # get_manager calls ensure_one() on the programme's payment managers, so it
            # raises when a programme has more than one. An unauthenticated route should
            # answer that as data rather than surface a server error.
            _logger.exception("Could not resolve the payment manager for batch %s", batch.id)
            manager = None
        if not manager or manager._name != "g2p.program.payment.manager.phee":
            # The programme no longer pays through Payment Hub, so this callback is
            # not ours to act on.
            _logger.warning("PHEE callback for batch %s whose programme is not on PHEE", batch.id)
            return self._json({"status": "not a payment hub batch"}, status=404)

        if not manager._phee_token_matches(token):
            _logger.warning("PHEE callback for batch %s carried a stale token", batch.id)
            return self._json({"status": "bad token"}, status=403)

        try:
            body = json.loads(request.httprequest.get_data() or b"{}")
        except ValueError:
            # Payment Hub sends the body with no Content-Type at all, so a parse
            # failure means a genuinely malformed body. Log it and carry on: the
            # reconciliation below does not need the body to work.
            _logger.warning("PHEE callback for batch %s had an unparseable body", batch.id)
            body = {}

        try:
            result = manager._phee_handle_callback(batch, body)
        except Exception:
            _logger.exception("PHEE callback handling failed for batch %s", batch.id)
            result = {"status": "callback handling failed", "retry": True}
        # A 2xx stops Payment Hub retrying. It retries maxCallbackRetry (3) times on
        # anything else, which is what should happen when the operations API was the
        # thing that failed - so that case, and only that case, answers 502.
        status = 502 if result.get("retry") else 200
        return self._json(result, status=status)
PYEOF2
  if [[ $rc -eq 0 ]]; then log_ok
  else log_warn "could not write the callback controller into ${PHEE_MODULE_DIR}/controllers — Payment Hub's POST would 404"; fi
}

#------------------------------------------------------------------------------
# Function : step_callback_cron
# Description: Step 5b — adds the reconcile scheduled action. It ships inactive and is
#              switched on the first time a batch is actually sent, so an install that
#              never pays costs nothing.
# Parameters:
#   $1 - pod name
#------------------------------------------------------------------------------
step_callback_cron() {
  local pod="$1"
  log_step "Adding the PHEE reconcile scheduled action"
  _write_pod_file "$pod" "${PHEE_MODULE_DIR}/data/ir_cron.xml" <<'XMLEOF'
<?xml version="1.0" encoding="utf-8" ?>
<!-- Added by Gazelle (src/utils/openg2p/setup-pbms-phee.sh). Not upstream OpenG2P.

     The safety net behind the callback, not the main path. Payment Hub retries a
     failed callback three times and never redelivers after that, so without this a
     dropped callback would leave a batch in state 'sent' for good.

     noupdate so re-running the module upgrade does not switch it back off after
     _phee_activate_cron has armed it. -->
<odoo noupdate="1">
    <record id="cron_phee_reconcile_payments" model="ir.cron">
        <field name="name">Payment Hub EE: Reconcile Sent Payments</field>
        <field name="model_id" ref="model_g2p_program_payment_manager_phee" />
        <field name="user_id" ref="base.user_root" />
        <field name="state">code</field>
        <field name="code">model.cron_phee_reconcile_payments()</field>
        <field name="interval_number">10</field>
        <field name="interval_type">minutes</field>
        <!-- Unlimited. This ir.cron build still carries numbercall, which counts DOWN
             per run and deactivates the record when it hits zero; its default is 1, so
             leaving it out makes the scheduled action a one-shot that switches itself
             off after a single sweep. -->
        <field name="numbercall">-1</field>
        <field name="active" eval="False" />
    </record>
</odoo>
XMLEOF
  if [[ $? -eq 0 ]]; then log_ok; else log_warn "could not write ${PHEE_MODULE_DIR}/data/ir_cron.xml"; fi
}

#------------------------------------------------------------------------------
# Function : step_callback_model
# Description: Step 5c — appends the callback and reconciliation logic to the upstream
#              payment manager. Appended rather than merged so the upstream classes are
#              left exactly as fetched, and guarded by PHEE_CB_MARKER so a re-run is a
#              no-op. Imports sit at the top of the block: a module-level import at the
#              bottom of a file is legal, and it keeps the block self-contained.
# Parameters:
#   $1 - pod name
#------------------------------------------------------------------------------
step_callback_model() {
  local pod="$1" out
  log_step "Appending callback reconciliation to payment_manager.py"
  # Replaced, not skipped-if-present: the block always sits at the end of the file, so
  # the previous one is cut from its BEGIN sentinel to EOF and a fresh copy appended.
  # A "skip when the marker is there" guard would silently keep stale code whenever the
  # block below is edited, which is the whole point of patching in place.
  # The file is kept aside and restored if the result does not parse, so a bad edit
  # cannot leave PBMS with a payment manager Odoo refuses to import.
  # Snapshot, then cut every previous block. Done in Python rather than sed because the
  # cut has to land on the FIRST line carrying the marker in any spelling: an earlier
  # version of this script wrote the marker without the -BEGIN suffix, and a pattern that
  # missed it appended a second copy instead of replacing the first. Trailing blank and
  # separator lines go too, so repeated runs converge on a byte-identical file.
  if ! kubectl exec -i -n "$NS" "$pod" -- bash -c "
      set -e
      [ -f '$PHEE_PM_FILE' ] || exit 3
      cp '$PHEE_PM_FILE' '$PHEE_PM_FILE.gazelle-prev'
      python3 - '$PHEE_PM_FILE' '$PHEE_CB_MARKER'" <<'TRIMEOF' >/dev/null 2>&1
import re
import sys

path, marker = sys.argv[1], sys.argv[2]
with open(path) as fh:
    lines = fh.readlines()
cut = next((i for i, line in enumerate(lines) if marker in line), len(lines))
kept = lines[:cut]
# The block was introduced by a comment rule and blank lines; drop them with it.
while kept and (not kept[-1].strip() or re.fullmatch(r"#[-\s]*", kept[-1].strip())):
    kept.pop()
with open(path, "w") as fh:
    fh.write("".join(kept).rstrip("\n") + "\n\n\n")
TRIMEOF
  then
    log_warn "could not trim the previous callback block from ${PHEE_PM_FILE} — reconciliation may be stale"
    return 0
  fi
  out="$(kubectl exec -i -n "$NS" "$pod" -- bash -c "
    set -e
    f='$PHEE_PM_FILE'
    cat >> \"\$f\"
    if ! python3 -c \"import ast; ast.parse(open('\$f').read())\" 2>/dev/null; then
      mv \"\$f.gazelle-prev\" \"\$f\"; echo SYNTAX_BROKEN; exit 4
    fi
    if cmp -s \"\$f.gazelle-prev\" \"\$f\"; then echo FILE_SAME; else echo FILE_REPLACED; fi
    rm -f \"\$f.gazelle-prev\"
  " <<'PYEOF'
# GAZELLE-PHEE-CALLBACK-BEGIN -----------------------------------------------
# Added by Gazelle (src/utils/openg2p/setup-pbms-phee.sh). Not upstream OpenG2P.
# Everything from this line to the end of the file is replaced on every re-run of
# that script, so edit it there and not here. The marker stays on the first line of
# the block, because the trim cuts from it to the end of the file.
#
# Callback-driven payment reconciliation. Upstream g2p_payment_phee posts the batch
# and stops there: the payments stay in state 'sent' and the beneficiary reads as not
# paid even after the money arrived. This closes that loop, following the same shape
# as OpenSPP's spp_payment_phee: the outcome per payment is read from Payment Hub's
# operations API, never inferred from the progress percentage.
# ---------------------------------------------------------------------------
import re  # noqa: E402

from requests.exceptions import RequestException  # noqa: E402

# Statuses treated as final. Anything else leaves the payment open rather than
# guessed, so a transfer still in flight is never reported as an outcome.
PHEE_STATUS_PAID = ("COMPLETED",)
PHEE_STATUS_FAILED = ("FAILED", "EXCEPTION", "REJECTED", "ABORTED")

# "The Batch Aggregation API was complete with : 75" -> 75
_PHEE_PROGRESS_RE = re.compile(r"(\d+)\s*$")

_PHEE_CRON_XMLID = "g2p_payment_phee.cron_phee_reconcile_payments"


class G2PPaymentBatchPhee(models.Model):
    """What Payment Hub told us about a batch, kept on the batch itself."""

    _inherit = "g2p.payment.batch"

    phee_batch_id = fields.Char(
        "Payment Hub Batch ID",
        copy=False,
        readonly=True,
        help="Payment Hub's own id for this batch, read out of the upload response. "
        "This is what its operations API is queried with, so reconciliation needs it; "
        "the External Batch Reference is our correlation id and is not interchangeable.",
    )
    phee_progress = fields.Integer(
        "Payment Hub Progress %",
        copy=False,
        readonly=True,
        help="Percentage from the last progress callback. Shown for information only - "
        "completion is decided by reading the outcome of every transfer, not from this.",
    )
    phee_callback_datetime = fields.Datetime(
        "Last Callback",
        copy=False,
        readonly=True,
    )
    phee_callback_note = fields.Text(
        "Last Callback Message",
        copy=False,
        readonly=True,
    )


class G2PPaymentHubEEManagerCallback(models.Model):
    """Callback wiring and reconciliation for the Payment Hub EE payment manager."""

    _inherit = "g2p.program.payment.manager.phee"

    callback_enabled = fields.Boolean(
        "Request Progress Callbacks",
        default=True,
        help="Send X-CallbackURL with the batch so Payment Hub posts progress back "
        "here. Turn it off to rely only on the reconcile scheduled action.",
    )
    callback_base_url = fields.Char(
        "Callback Base URL",
        help="Base URL Payment Hub should post batch progress to, as reachable from "
        "the Payment Hub namespace - normally this PBMS Service's cluster DNS name. "
        "Leave empty and no callback is requested.",
    )
    callback_token = fields.Char(
        "Callback Token",
        copy=False,
        help="Generated once and embedded in the callback URL. Payment Hub cannot "
        "authenticate, so this is what makes the URL a capability rather than a "
        "guessable path. Clear it to rotate; batches already in flight will then "
        "fall back to the reconcile scheduled action.",
    )

    # --- The callback URL handed to Payment Hub -------------------------------

    def _phee_token(self):
        """This manager's callback token, generated on first use."""
        self.ensure_one()
        if not self.callback_token:
            # sudo(): send_payments can run as a user with no write on the manager.
            # nosemgrep: odoo-sudo-without-context
            self.sudo().callback_token = uuid4().hex
        return self.callback_token

    def _phee_token_matches(self, token):
        """True when a callback carried this manager's current token."""
        self.ensure_one()
        current = self.callback_token or ""
        return bool(current) and token == current

    def _phee_callback_url(self, batch):
        """The URL Payment Hub should post this batch's progress to, or "".

        The batch reference goes in the path because nothing in the callback body
        identifies the batch on our side: its clientCorrelationId is a Zeebe key and
        its batchId is Payment Hub's own, neither of which PBMS ever saw.
        """
        self.ensure_one()
        if not self.callback_enabled or not self.callback_base_url:
            return ""
        ref = batch.external_batch_ref or batch.name
        if not ref:
            return ""
        return "%s/g2p/phee/callback/%s/%s" % (
            self.callback_base_url.rstrip("/"),
            self._phee_token(),
            ref,
        )

    def _phee_callback_headers(self, batch):
        """The X-CallbackURL header, or no header at all.

        Merged into the upload headers by the one line patched into send_payments.
        Returns an empty dict rather than an empty header value: Payment Hub logs a
        missing header as "callback url is null" and carries on, where an empty
        string is a URL it would try to post to.

        Never raises. It sits on the path that sends real money, and a callback that
        cannot be set up is not a reason to fail the payment - the reconcile
        scheduled action still picks the batch up.
        """
        try:
            url = self._phee_callback_url(batch)
        except Exception:
            _logger.exception("Could not build the PHEE callback URL for batch %s", batch.id)
            return {}
        return {"X-CallbackURL": url} if url else {}

    def _phee_after_send(self, batch, response_body):
        """Record Payment Hub's batch id and arm the reconcile scheduled action.

        Called from send_payments once the upload was accepted. Never raises, for the
        same reason as _phee_callback_headers, and more sharply: by this point the
        money is already on its way and the batch is marked started, so an exception
        here would roll that back and the next run would pay twice.
        """
        try:
            batch_id = self._phee_extract_batch_id(response_body)
            if batch_id:
                batch.phee_batch_id = batch_id
            else:
                _logger.warning(
                    "Payment Hub returned no batch id for batch %s, so it cannot be "
                    "reconciled until one is known",
                    batch.id,
                )
            self._phee_activate_cron(_PHEE_CRON_XMLID)
        except Exception:
            _logger.exception("Post-send bookkeeping failed for batch %s", batch.id)

    @api.model
    def _phee_extract_batch_id(self, body):
        """Payment Hub's own batch id, out of the upload response body.

        The bulk processor answers 202 with {"PollingPath": "/batch/Summary/<id>",
        "SuggestedCallbackSeconds": "120"}, so the id is the tail of that path.
        """
        if not isinstance(body, dict):
            return ""
        if body.get("batch_id"):
            return str(body["batch_id"])
        polling_path = body.get("PollingPath") or ""
        if polling_path:
            return polling_path.rstrip("/").rsplit("/", 1)[-1]
        return ""

    # --- Handling one callback ------------------------------------------------

    @api.model
    def _phee_parse_progress(self, message):
        """The trailing percentage of the callback message, or None."""
        found = _PHEE_PROGRESS_RE.search(message or "")
        return int(found.group(1)) if found else None

    def _phee_handle_callback(self, batch, body):
        """Record one progress callback, then reconcile the batch behind it.

        The percentage is stored for display and nothing is concluded from it. It is
        an aggregate with no per-payment detail, and it does not reliably reach 100:
        Payment Hub stops chasing a batch once completionRate passes its threshold or
        maxStatusRetry runs out, so a batch with a stuck transfer keeps reporting
        below 100 forever. Completion is decided by reading every transfer instead,
        which also lets such a batch complete the moment its last transfer resolves.
        """
        self.ensure_one()
        message = str(body.get("message") or "")
        vals = {
            "phee_callback_datetime": fields.Datetime.now(),
            "phee_callback_note": message[:2000],
        }
        progress = self._phee_parse_progress(message)
        if progress is not None:
            vals["phee_progress"] = progress
        # Only when we have none: ours came from the upload response, which is the
        # more trustworthy source, and it should not be overwritten per callback.
        if body.get("batchId") and not batch.phee_batch_id:
            vals["phee_batch_id"] = str(body["batchId"])
        batch.write(vals)
        return self._reconcile_batch(batch)

    # --- Reconciliation -------------------------------------------------------

    def _phee_detail_url(self):
        """The operations API transfer-detail endpoint, or "" when not configured.

        Prefers details_endpoint_url and falls back to status_endpoint_url. Both
        default to the .../api/v1/batch base, so /detail is appended unless the
        configured value already carries it.
        """
        self.ensure_one()
        base = (self.details_endpoint_url or self.status_endpoint_url or "").strip().rstrip("/")
        if not base:
            return ""
        return base if base.endswith("/detail") else base + "/detail"

    def _phee_batches_url(self):
        """The operations API batch-list endpoint, or "".

        Derived from the same configured base as the detail endpoint, which is the
        .../api/v1/batch collection: its listing sibling is .../api/v1/batches.
        """
        self.ensure_one()
        base = (self.details_endpoint_url or self.status_endpoint_url or "").strip().rstrip("/")
        if base.endswith("/detail"):
            base = base[: -len("/detail")]
        if not base.endswith("/batch"):
            return ""
        return base[: -len("/batch")] + "/batches"

    def _phee_recover_batch_id(self, batch):
        """Find Payment Hub's batch id for a batch that has none recorded, or "".

        Two cases need this: a batch sent before this reconciliation existed, and one
        whose upload response could not be parsed. Neither could ever reconcile
        otherwise, because the operations API is only queryable by that id.

        The way back is the filename: the upload is named "<prefix><batch name>.csv" and
        the operations API lists it as requestFile, prefixed with an id of its own.
        """
        self.ensure_one()
        list_url = self._phee_batches_url()
        if not list_url or not batch.name:
            return ""
        needle = "%s%s" % (self.file_name_prefix or "", batch.name)
        try:
            res = requests.get(
                list_url,
                headers={"Platform-TenantId": self.tenant_id},
                timeout=self.batch_request_timeout or 30,
                verify=False,
            )
            res.raise_for_status()
            rows = res.json().get("data") or []
        except (RequestException, ValueError):
            _logger.exception("Could not list Payment Hub batches for batch %s", batch.id)
            return ""
        for row in rows:
            if needle in (row.get("requestFile") or ""):
                return str(row.get("batchId") or "")
        return ""

    def _reconcile_batch(self, batch):
        """Read the outcome of one batch back from Payment Hub's operations API.

        Payment Hub accepts the upload and works through it asynchronously, so PBMS
        only learns what happened by asking. Each transfer row carries the CSV
        request_id back as clientCorrelationId - quoted, hence the strip - and that is
        the g2p.payment name, so it is the key that ties a row to a payment.

        A failure is written as reconciled/failed, not left open: prepare_payments
        re-pays an entitlement only when its payments are reconciled and failed, so
        anything else would make the entitlement permanently unpayable.
        """
        self.ensure_one()
        url = self._phee_detail_url()
        if not url:
            return {"status": "reconciliation not configured"}
        if not batch.phee_batch_id:
            recovered = self._phee_recover_batch_id(batch)
            if not recovered:
                return {"status": "no payment hub batch id"}
            batch.phee_batch_id = recovered
            _logger.info(
                "Recovered Payment Hub batch id %s for batch %s", recovered, batch.id
            )

        try:
            res = requests.get(
                url,
                params={"batchId": batch.phee_batch_id, "pageSize": 1000},
                headers={"Platform-TenantId": self.tenant_id},
                timeout=self.batch_request_timeout or 30,
                verify=False,
            )
            res.raise_for_status()
            rows = res.json().get("content") or []
        except (RequestException, ValueError):
            _logger.exception("Could not read batch %s back from Payment Hub", batch.id)
            # retry=True so the controller answers 502 and Payment Hub calls again.
            return {"status": "operations api unreachable", "retry": True}

        now = fields.Datetime.now()
        paid = failed = 0
        for entry in rows:
            reference = str(entry.get("clientCorrelationId") or "").strip('"')
            status = str(entry.get("status") or "").upper()
            # Matched inside the batch, not across the database: the rows came from a
            # query by batch id, so the payment can only be one of these.
            payment = batch.payment_ids.filtered(lambda p, r=reference: p.name == r)[:1]
            if not payment or payment.status_is_final:
                continue
            if status in PHEE_STATUS_PAID:
                payment.write(
                    {
                        "state": "reconciled",
                        "status": "paid",
                        "status_is_final": True,
                        "status_datetime": now,
                        "amount_paid": payment.amount_issued,
                        "payment_datetime": now,
                    }
                )
                paid += 1
            elif status in PHEE_STATUS_FAILED:
                payment.write(
                    {
                        "state": "reconciled",
                        "status": "failed",
                        "status_is_final": True,
                        "status_datetime": now,
                    }
                )
                failed += 1

        self._phee_refresh_batch_stats(batch)
        # Every payment, not just every row returned: Payment Hub creates a transfer
        # row per payment as it gets to it, so early on there are fewer rows than
        # payments and "no row is pending" would complete the batch too soon.
        if batch.payment_ids and all(p.status_is_final for p in batch.payment_ids):
            if not batch.batch_has_completed:
                batch.batch_has_completed = True
                _logger.info(
                    "Batch %s reconciled and complete (%s payments)",
                    batch.id,
                    len(batch.payment_ids),
                )
        return {
            "status": "ok",
            "batchId": batch.phee_batch_id,
            "progress": batch.phee_progress,
            "reconciled": paid + failed,
            "paid": paid,
            "failed": failed,
            "completed": batch.batch_has_completed,
        }

    @api.model
    def _phee_refresh_batch_stats(self, batch):
        """Refresh the batch statistics columns so the form shows the outcome.

        They are readonly in the UI and nothing else fills them, so without this the
        batch form keeps reading zero paid however the transfers went.
        """
        payments = batch.payment_ids
        paid = payments.filtered(lambda p: p.status == "paid")
        failed = payments.filtered(lambda p: p.status == "failed")
        sent = payments.filtered(lambda p: p.state in ("sent", "reconciled"))
        batch.write(
            {
                "stats_issued_transactions": len(payments),
                "stats_issued_amount": sum(payments.mapped("amount_issued")),
                "stats_sent_transactions": len(sent),
                "stats_sent_amount": sum(sent.mapped("amount_issued")),
                "stats_paid_transactions": len(paid),
                "stats_paid_amount": sum(paid.mapped("amount_paid")),
                "stats_failed_transactions": len(failed),
                "stats_failed_amount": sum(failed.mapped("amount_issued")),
                "stats_datetime": fields.Datetime.now(),
            }
        )

    # --- The scheduled action behind the callback ------------------------------

    @api.model
    def _phee_activate_cron(self, xml_id):
        """Switch the reconcile scheduled action on, and keep it repeatable.

        It ships inactive, so an install that never pays costs nothing.

        numbercall is reset alongside active because this ir.cron build still counts it
        down on every run and deactivates the record when it reaches zero. Its default
        is 1, so an action armed without it runs a single sweep and switches itself off
        - which looks exactly like reconciliation quietly not working. Repairing it here
        rather than only in the data file matters because that record is noupdate, so a
        module upgrade will not correct one that has already burned down.
        """
        cron = self.env.ref(xml_id, raise_if_not_found=False)
        if not cron:
            return
        vals = {}
        if not cron.active:
            vals["active"] = True
        if "numbercall" in cron._fields and cron.numbercall != -1:
            vals["numbercall"] = -1
        if vals:
            # nosemgrep: odoo-sudo-without-context
            cron.sudo().write(vals)

    @api.model
    def cron_phee_reconcile_payments(self):
        """Reconcile every batch that was sent and has not completed.

        The safety net, not the main path: the callback normally gets there first and
        this finds nothing to do. It exists because Payment Hub gives up on a callback
        after three tries and never redelivers.
        """
        batches = self.env["g2p.payment.batch"].search(
            [("batch_has_started", "=", True), ("batch_has_completed", "=", False)]
        )
        if not batches:
            return
        # Resolve the manager once per programme rather than once per batch.
        for program in batches.mapped("cycle_id.program_id"):
            manager = program.get_manager(program.MANAGER_PAYMENT)
            if not manager or manager._name != self._name:
                continue
            for batch in batches.filtered(lambda b, p=program: b.cycle_id.program_id == p):
                try:
                    manager._reconcile_batch(batch)
                except Exception:
                    # One unreadable batch must not stop the rest of the sweep.
                    _logger.exception("Reconciliation of batch %s failed", batch.id)
PYEOF
)"
  if [[ "$out" == *FILE_REPLACED* ]]; then
    PHEE_CB_SOURCE_CHANGED=true
    log_ok
  elif [[ "$out" == *FILE_SAME* ]]; then
    log_ok
    log_with_verbose_check "$debug" "$DEBUG" "callback model block already up to date"
  else
    log_warn "callback model block not applied to ${PHEE_PM_FILE} (${out:-no output}) — reconciliation will not run"
  fi
}

#------------------------------------------------------------------------------
# Function : step_patch_send_callback
# Description: Step 5d — the only two edits to upstream code in send_payments: ask for
#              the callback on the upload, and keep Payment Hub's batch id off the
#              response. Both anchored on lines unique to that method, and both skip
#              when already applied.
# Parameters:
#   $1 - pod name
#------------------------------------------------------------------------------
step_patch_send_callback() {
  local pod="$1"
  log_step "Patching send_payments to request the callback"
  kubectl exec -n "$NS" "$pod" -- bash -c "
    set -e
    f='${PHEE_PM_FILE}'
    [ -f \"\$f\" ] || { echo NO_FILE; exit 3; }
    # 1. Merge the X-CallbackURL header into the upload headers. A dict-merge rather
    #    than a literal entry so no header is sent at all when callbacks are off.
    if ! grep -q '_phee_callback_headers(batch)' \"\$f\"; then
      sed -i 's|^\(\s*\)\"X-CorrelationID\": x_correlation_id,\s*\$|\1\"X-CorrelationID\": x_correlation_id,\n\1**self._phee_callback_headers(batch),|' \"\$f\"
    fi
    # 2. Keep Payment Hub's own batch id, which the operations API is queried with.
    #    Anchored after batch_has_started so it only runs on an accepted upload.
    if ! grep -q '_phee_after_send(batch' \"\$f\"; then
      sed -i 's|^\(\s*\)batch\.batch_has_started = True\s*\$|\1batch.batch_has_started = True\n\1self._phee_after_send(batch, jsonResponse)|' \"\$f\"
    fi
    grep -q '_phee_callback_headers(batch)' \"\$f\" || { echo HEADER_PATCH_FAILED; exit 4; }
    grep -q '_phee_after_send(batch' \"\$f\"       || { echo AFTERSEND_PATCH_FAILED; exit 5; }
    python3 -c \"import ast,sys; ast.parse(open('\$f').read())\" || { echo SYNTAX_BROKEN; exit 6; }
    echo PATCHED
  " >/dev/null 2>&1
  local rc=$?
  if [[ $rc -eq 0 ]]; then log_ok
  else log_warn "send_payments callback patch not applied (rc=$rc) — no X-CallbackURL will be sent; edit ${PHEE_PM_FILE} by hand"; fi
}

#------------------------------------------------------------------------------
# Function : step_wire_callback_module
# Description: Step 5e — puts the new files on the module's own import and data paths:
#              the controllers package into __init__.py, the cron into the manifest.
#              Without these Odoo loads neither.
# Parameters:
#   $1 - pod name
#------------------------------------------------------------------------------
step_wire_callback_module() {
  local pod="$1"
  log_step "Wiring the controller and cron into the module"
  kubectl exec -n "$NS" "$pod" -- bash -c "
    set -e
    d='${PHEE_MODULE_DIR}'
    init=\"\$d/__init__.py\"
    man=\"\$d/__manifest__.py\"
    [ -f \"\$init\" ] && [ -f \"\$man\" ] || { echo NO_FILE; exit 3; }
    grep -q 'from . import controllers' \"\$init\" || printf 'from . import controllers\n' >> \"\$init\"
    if ! grep -q 'data/ir_cron.xml' \"\$man\"; then
      sed -i 's|^\(\s*\)\"security/ir\.model\.access\.csv\",\s*\$|\1\"security/ir.model.access.csv\",\n\1\"data/ir_cron.xml\",|' \"\$man\"
    fi
    grep -q 'from . import controllers' \"\$init\" || { echo INIT_FAILED; exit 4; }
    grep -q 'data/ir_cron.xml' \"\$man\"           || { echo MANIFEST_FAILED; exit 5; }
    python3 -c \"import ast; ast.parse(open('\$man').read())\" || { echo SYNTAX_BROKEN; exit 6; }
    echo WIRED
  " >/dev/null 2>&1
  local rc=$?
  if [[ $rc -eq 0 ]]; then log_ok
  else log_warn "module wiring failed (rc=$rc) — the callback route and cron will not load"; fi
}

#------------------------------------------------------------------------------
# Function : step_callback_upgrade
# Description: Step 5f — upgrades g2p_payment_phee so the new columns are created and
#              the cron record is loaded, then rolls Odoo so the web workers serve the
#              new route (a controller is imported at process start, not on upgrade).
#              Skips both when the columns are already there, which is the re-run case.
# Parameters:
#   $1 - pod name
#------------------------------------------------------------------------------
step_callback_upgrade() {
  local pod="$1"
  log_step "Checking whether g2p_payment_phee needs upgrading for the callback"
  if _odoo_shell "$pod" PHEE_CB_FIELDS_PRESENT <<'PYEOF'
Batch = env.get('g2p.payment.batch')
Mgr = env.get('g2p.program.payment.manager.phee')
have = (
    Batch is not None and 'phee_batch_id' in Batch._fields
    and Mgr is not None and 'callback_base_url' in Mgr._fields
    and env.ref('g2p_payment_phee.cron_phee_reconcile_payments', raise_if_not_found=False)
)
print('PHEE_CB_FIELDS_PRESENT' if have else 'PHEE_CB_FIELDS_MISSING')
PYEOF
  then
    log_ok
    log_with_verbose_check "$debug" "$DEBUG" "callback fields and cron already installed — no upgrade needed"
    # No upgrade, but changed source still has to be loaded: Odoo imports a controller
    # at process start, so without this a re-run would keep serving the old route.
    if [[ "$PHEE_CB_SOURCE_CHANGED" == true ]]; then
      log_with_verbose_check "$debug" "$DEBUG" "callback source changed — rolling Odoo so the new route is served"
      _restart_odoo
    fi
    return 0
  fi
  log_ok
  log_step "Upgrading g2p_payment_phee (adds the callback fields and cron)"
  # bg-task writes to ir_module_module trip Postgres serialization errors during an
  # upgrade, the same way they do during an install.
  _bgtask_scale 0 >/dev/null 2>&1
  local upgraded=false
  if _odoo_shell_verbose "$pod" PHEE_CB_UPGRADE_OK <<'PYEOF'
m = env["ir.module.module"].search([("name", "=", "g2p_payment_phee")], limit=1)
if not m:
    print("MISSING_MODULE g2p_payment_phee")
elif m.state != "installed":
    print("NOT_INSTALLED", m.state)
else:
    m.button_immediate_upgrade()
    env.cr.commit()
    print("PHEE_CB_UPGRADE_OK")
PYEOF
  then
    upgraded=true
  fi
  _bgtask_scale 1 >/dev/null 2>&1
  if [[ "$upgraded" == true ]]; then log_ok; else log_warn "upgrade of g2p_payment_phee did not complete — the callback fields and cron are missing"; fi
  # The route lives in a controller, which Odoo imports at process start. Without this
  # the fields exist but Payment Hub's POST 404s.
  _restart_odoo
}

#------------------------------------------------------------------------------
# Function : step_callback_config
# Description: Step 5g — points the PHEE payment manager(s) at this cluster: where
#              Payment Hub should post progress, and where to read the outcome back.
#              Only fills what is empty or still on the upstream sandbox default, so a
#              deployment that set its own URLs keeps them.
# Parameters:
#   $1 - pod name
#------------------------------------------------------------------------------
step_callback_config() {
  local pod="$1"
  log_step "Pointing the PHEE manager at this cluster's callback and ops API"
  _odoo_shell "$pod" PHEE_CB_CONFIG_OK <<PYEOF
import uuid
Mgr = env.get('g2p.program.payment.manager.phee')
n = 0
if Mgr is not None and 'callback_base_url' in Mgr._fields:
    for m in Mgr.sudo().search([]):
        vals = {}
        if not m.callback_base_url:
            vals['callback_base_url'] = '${PHEE_CB_BASE_URL}'
        if not m.callback_enabled:
            vals['callback_enabled'] = True
        # Provisioned and committed here rather than left to the lazy generation in
        # _phee_token(): that one writes inside the transaction that posts the batch, so
        # a rollback after the POST would strand Payment Hub holding a URL whose token
        # no longer exists, and every callback for that batch would be rejected.
        if not m.callback_token:
            vals['callback_token'] = uuid.uuid4().hex
        # These two only became load-bearing with the reconciliation below, so what is
        # already there is a placeholder rather than a choice: the upstream default is
        # OpenG2P's public sandbox, and openg2p-data-setup.sh used to fill them with the
        # batch UPLOAD url. Neither can answer a transfer-detail query. Anything that
        # does look like the operations batch API is left alone.
        for f in ('status_endpoint_url', 'details_endpoint_url'):
            if '/api/v1/batch' not in (m[f] or ''):
                vals[f] = '${PHEE_OPS_API_URL}'
        if vals:
            m.write(vals)
            n += 1
    env.cr.commit()
    if not Mgr.sudo().search_count([]):
        # Not a failure, but say so: on a fresh database the payment manager does not
        # exist yet. openg2p-data-setup.sh creates it later and sets the callback fields
        # itself, so silence here would look like the callback was configured when the
        # step had nothing to configure.
        print('PHEE_CB_NO_MANAGER_YET')
print('PHEE_CB_CONFIG_OK', n)
PYEOF
  local cfg_rc=$?
  # Repair a cron that already burned its numbercall down to zero and switched itself
  # off. The record is noupdate, so the corrected data file does not reach an existing
  # one; without this a PBMS deployed before that fix keeps a one-shot scheduled action.
  _odoo_shell "$pod" PHEE_CB_CRON_OK <<'PYEOF'
c = env.ref('g2p_payment_phee.cron_phee_reconcile_payments', raise_if_not_found=False)
notes = []
if c:
    vals = {}
    if 'numbercall' in c._fields and c.numbercall != -1:
        vals['numbercall'] = -1
        notes.append('numbercall')
    # Arm it when a batch is already in flight. Normally a send arms it, but for a batch
    # sent before this fix that send has been and gone, so it would otherwise sit
    # unreconciled until the next one.
    outstanding = env['g2p.payment.batch'].sudo().search_count(
        [('batch_has_started', '=', True), ('batch_has_completed', '=', False)])
    if outstanding and not c.active:
        vals['active'] = True
        notes.append('armed for %d batch(es) in flight' % outstanding)
    if vals:
        c.sudo().write(vals)
        env.cr.commit()
print('PHEE_CB_CRON_OK', '; '.join(notes))
PYEOF
  if [[ $cfg_rc -eq 0 ]]; then log_ok
  else log_warn "could not configure the callback URL — set Callback Base URL and Status Endpoint URL on the PHEE payment manager by hand"; fi
}

#------------------------------------------------------------------------------
# Function : step_verify_callback_route
# Description: Step 5h — confirms the callback route is actually registered. Posts a
#              reference no batch has: the route answers that with its own JSON body,
#              where an unregistered route gives Odoo's HTML 404. Both are 404, so the
#              body is what distinguishes "route live" from "controller never loaded".
# Parameters:
#   $1 - pod name
#------------------------------------------------------------------------------
step_verify_callback_route() {
  local pod="$1" body
  log_step "Verifying the callback route is registered"
  body="$(kubectl exec -n "$NS" "$pod" -- bash -lc \
    "curl -s -X POST -d '{}' 'http://localhost:8069/g2p/phee/callback/probe/gazelle-route-probe'" 2>/dev/null)"
  if [[ "$body" == *"unknown batch"* ]]; then
    log_ok
  else
    log_warn "callback route did not answer as expected — Payment Hub's progress POST will not land"
    log_with_verbose_check "$debug" "$DEBUG" "route probe returned: ${body:0:200}"
  fi
}

#------------------------------------------------------------------------------
# main
#------------------------------------------------------------------------------
main() {
  log_section "Enabling g2p_payment_phee on PBMS (namespace: $NS)"

  command -v kubectl  >/dev/null 2>&1 || { log_error "kubectl not found on PATH"; exit 1; }
  command -v crudini  >/dev/null 2>&1 || { log_error "crudini not found on PATH"; exit 1; }
  command -v curl     >/dev/null 2>&1 || { log_error "curl not found on PATH"; exit 1; }

  local pod
  pod="$(_find_pbms_pod)"
  if [[ -z "$pod" ]]; then
    log_error "no Running pbms-odoo pod in namespace '$NS' — deploy PBMS first (./run.sh -m deploy -a openg2p)"
    exit 1
  fi
  log_with_level "$INFO" "Using pod: $pod"

  step_download_addons  "$pod"
  step_check_addons_dir "$pod"
  step_patch_amount     "$pod"
  # The callback source lands before the install, so a fresh install already carries the
  # fields, the cron and the route and needs no upgrade afterwards.
  step_callback_controller  "$pod"
  step_callback_cron        "$pod"
  step_callback_model       "$pod"
  step_patch_send_callback  "$pod"
  step_wire_callback_module "$pod"
  step_stub_and_install "$pod"
  # re-resolve the pod: the module-install restart rolls a new pod
  pod="$(_find_pbms_pod)"; [[ -n "$pod" ]] || { log_error "pbms-odoo pod gone after restart"; exit 1; }
  step_batch_header     "$pod"
  # Only does anything when the module was already installed before this feature, in
  # which case it upgrades and rolls Odoo, so the pod is re-resolved after it.
  step_callback_upgrade "$pod"
  pod="$(_find_pbms_pod)"; [[ -n "$pod" ]] || { log_error "pbms-odoo pod gone after callback upgrade"; exit 1; }
  step_callback_config  "$pod"

  log_step "Verifying /web/login serves (200)"
  local code
  code="$(kubectl exec -n "$NS" "$pod" -- bash -lc 'curl -s -o /dev/null -w "%{http_code}" http://localhost:8069/web/login' 2>/dev/null)"
  if [[ "$code" == "200" ]]; then log_ok; else log_warn "login returned HTTP $code — check: kubectl logs -n $NS $pod | grep -i error"; fi

  step_verify_callback_route "$pod"

  log_banner "g2p_payment_phee setup complete"
  log_with_level "$INFO" "Verify: kubectl exec -n $NS \$(kubectl get po -n $NS -o name | grep pbms-odoo | head -1) -- ls $ADDONS_DIR"
  log_with_level "$INFO" "Then trigger a PBMS->PHEE batch and confirm total > 0 (no fileName/NumberFormat errors)."
  log_with_level "$INFO" "Payment Hub posts progress to ${PHEE_CB_BASE_URL}/g2p/phee/callback/<token>/<external_batch_ref>;"
  log_with_level "$INFO" "  the batch completes once every payment has an outcome, and 'Payment Hub EE: Reconcile Sent Payments' is the fallback."
}

main "$@"
