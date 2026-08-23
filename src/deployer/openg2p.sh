#!/usr/bin/env bash
# openg2p.sh -- Mifos Gazelle deployer script for OpenG2P
#
# Each OpenG2P module is its own helm release so subchart-generated object names
# never collide across modules. Deploy order: CRDs, then commons (the shared
# Postgres + Keycloak foundation — deployed only when a module that uses it is
# enabled; skipped for a self-contained PBMS-only run), then each enabled module
# gated on its own pods being ready.

OPENG2P_HELM_DIR="${BASE_DIR}/src/deployer/helm/openg2p"
OPENG2P_CRDS_DIR="${BASE_DIR}/src/deployer/manifests/openg2p"

# Module deploy order. g2p-bridge last because it depends on the spar mapper.
OPENG2P_MODULES=(social-registry pbms spar g2p-bridge)

#------------------------------------------------------------------------------
# Function : _openg2p_check_arch
# Description: Arch gate based on the CLUSTER NODES (where the pods actually run),
#              NOT on the host running this script — a remote deploy can drive an
#              amd64 cluster from an arm64 workstation, so `uname -m` here is
#              misleading. Falls back to the host arch only if kubectl can't reach
#              the cluster yet.
#              On amd64 nodes every OpenG2P config works. On arm64 nodes only the
#              PBMS-only demo is supported — it is fully multi-arch (pbms-core
#              rebuild, bitnamilegacy postgres/redis, postgres:16-alpine checker,
#              and commons skipped). social-registry/spar/g2p-bridge still need
#              commons (Keycloak/keycloak-init/postgres-init), which ship amd64-only
#              upstream, so those configs are refused on arm64.
# Returns: 0 when the enabled config can run on the node arch; 1 otherwise.
#------------------------------------------------------------------------------
_openg2p_check_arch() {
  local node_arch
  node_arch=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null)
  [[ -z "$node_arch" ]] && node_arch=$(uname -m)

  # amd64 / x86_64 nodes: nothing to gate.
  [[ "$node_arch" == "amd64" || "$node_arch" == "x86_64" ]] && return 0

  # arm64 nodes: PBMS-only is fine; the commons-backed modules are not.
  if _openg2p_commons_needed; then
    log_error "OpenG2P on ${node_arch} nodes: social-registry/spar/g2p-bridge require"
    log_error "commons (Keycloak/keycloak-init/postgres-init), which are amd64-only upstream."
    log_error "On arm64 run PBMS-only (disable those modules), or deploy on amd64 nodes."
    return 1
  fi
  return 0
}

#------------------------------------------------------------------------------
# Function : deploy_openg2p
# Description: Top-level entry point — deploys commons, then each enabled module
#              as its own helm release into the openg2p namespace on GAZELLE_DOMAIN.
#------------------------------------------------------------------------------
deploy_openg2p() {
  log_section "Deploying OpenG2P"

  # OpenG2P images are amd64-only — bail early on ARM rather than fail mid-deploy.
  _openg2p_check_arch || return 1

  if is_app_running "$OPENG2P_NAMESPACE"; then
    if [[ "$redeploy" == "false" ]]; then
      echo "    OpenG2P already deployed — skipping."
      return 0
    fi
  fi

  log_step "Creating namespace $OPENG2P_NAMESPACE"
  create_namespace "$OPENG2P_NAMESPACE"
  log_ok

  log_step "Creating OpenG2P TLS secret"
  create_ingress_secret "$OPENG2P_NAMESPACE" \
    "openg2p.$GAZELLE_DOMAIN" \
    "openg2p-tls" \
    "social-registry.$GAZELLE_DOMAIN,pbms.$GAZELLE_DOMAIN,spar.$GAZELLE_DOMAIN,g2p-bridge.$GAZELLE_DOMAIN,keycloak.$GAZELLE_DOMAIN,*.$GAZELLE_DOMAIN"
  log_ok

  # OpenG2P charts emit Istio/logging/monitoring objects Gazelle has no controllers for.
  # Install just their CRDs so the objects apply harmlessly; traffic routes via NGINX.
  log_step "Installing OpenG2P prerequisite CRDs (Istio, logging, monitoring)"
  kubectl apply -f "$OPENG2P_CRDS_DIR/istio-networking-crds.yaml" > /dev/null 2>&1
  kubectl apply -f "$OPENG2P_CRDS_DIR/optional-operator-crds.yaml" > /dev/null 2>&1
  log_ok

  # Tear down disabled module releases first: leftover crashing pods from a disabled
  # module would otherwise block the namespace-wide readiness waits below.
  local module enabled
  for module in "${OPENG2P_MODULES[@]}"; do
    enabled=$(_openg2p_module_enabled "$module")
    if [[ "$enabled" != "true" ]] && helm status "$module" -n "$OPENG2P_NAMESPACE" > /dev/null 2>&1; then
      log_step "Removing disabled OpenG2P module '$module'"
      _clean_openg2p_release "$module"
      log_ok
    fi
  done

  # Commons (Postgres + Keycloak) is the shared foundation for social-registry,
  # spar and g2p-bridge — but PBMS is self-contained and consumes none of it.
  # Deploy commons only when a module actually needs it; for a PBMS-only run skip
  # it entirely (an empty commons release would just hang the readiness gate for
  # startup_timeout before failing, since it can't tell "no pods yet" from "no
  # pods ever"). When it IS needed it stays the hard dependency: an unhealthy
  # commons is fatal, as the modules can only fail against a broken foundation.
  if _openg2p_commons_needed; then
    if ! _deploy_openg2p_release "openg2p-commons" "openg2p-commons"; then
      log_error "OpenG2P commons did not become ready — aborting OpenG2P deploy"
      return 1
    fi
  else
    log_skipped "OpenG2P commons not needed — no shared-DB/SSO module enabled (PBMS is self-contained); skipping"
    # Tear down a commons left over from a previous full deploy so a PBMS-only run
    # doesn't keep an unused Postgres/Keycloak (and its custom amd64 images) around.
    if helm status "openg2p-commons" -n "$OPENG2P_NAMESPACE" > /dev/null 2>&1; then
      log_step "Removing unused OpenG2P commons release"
      _clean_openg2p_release "openg2p-commons"
      log_ok
    fi
  fi

  # Deploy each enabled module as its own release, gated per-release on its own pods.
  # A failed module is recorded and the loop CONTINUES — reported at the end, never sticks.
  local failed_modules=()
  for module in "${OPENG2P_MODULES[@]}"; do
    enabled=$(_openg2p_module_enabled "$module")
    if [[ "$enabled" != "true" ]]; then
      log_skipped "OpenG2P module '$module' is disabled — skipping"
      continue
    fi
    # Create secrets the chart expects a monolithic install to have made (see function).
    _openg2p_preflight_secrets "$module"

    # release name == module name (short, unique prefix → no cross-module collisions)
    if ! _deploy_openg2p_release "openg2p-$module" "$module"; then
      failed_modules+=("$module")
      log_warn "OpenG2P module '$module' is not fully ready — continuing with remaining modules"
    else
      # Module is up — run any post-deploy fixups it needs (idempotent).
      _openg2p_postdeploy "$module"
    fi
  done

  if [[ "${#failed_modules[@]}" -gt 0 ]]; then
    local grep_alt
    grep_alt=$(IFS='|'; echo "${failed_modules[*]}")   # join with '|' for grep -E
    log_warn "OpenG2P deployed with unready module(s): ${failed_modules[*]}"
    log_warn "Inspect with: kubectl get pods -n $OPENG2P_NAMESPACE | grep -E '${grep_alt}'"
  fi
  log_banner "OpenG2P Deployed"
  _openg2p_print_urls
}

#------------------------------------------------------------------------------
# Function : _openg2p_print_urls
# Description: Prints access URLs for the enabled OpenG2P modules on GAZELLE_DOMAIN.
#------------------------------------------------------------------------------
_openg2p_print_urls() {
  local d="$GAZELLE_DOMAIN"
  local fmt="    %-18s%s\n"
  printf "\n  OpenG2P modules:\n"
  [[ "$(_openg2p_module_enabled social-registry)" == "true" ]] && \
    printf "$fmt" "Social Registry:"  "https://social-registry.$d"
  [[ "$(_openg2p_module_enabled pbms)" == "true" ]] && \
    printf "$fmt" "PBMS:"             "https://pbms.$d"
  [[ "$(_openg2p_module_enabled spar)" == "true" ]] && \
    printf "$fmt" "SPAR (API):"       "https://spar.$d/api/mapper"
  [[ "$(_openg2p_module_enabled g2p-bridge)" == "true" ]] && \
    printf "$fmt" "G2P Bridge (API):" "https://g2p-bridge.$d"
  # Keycloak is the only shared commons UI (MinIO/Kafka-UI/OpenSearch have no
  # consumer and stay disabled). It exists only when commons was deployed — i.e.
  # a PBMS-only run has no commons and nothing to link here.
  if _openg2p_commons_needed; then
    printf "$fmt" "Keycloak:"           "https://keycloak.$d"
  fi
}

#------------------------------------------------------------------------------
# Function : _deploy_openg2p_release
# Description: Idempotently deploys one helm release and gates on its pods becoming
#              ready. Healthy releases are skipped; failed ones are torn down and
#              reinstalled.
#   $1 = chart dir name under helm/openg2p/ (e.g. openg2p-commons)
#   $2 = helm release name                  (e.g. openg2p-commons, pbms)
# Returns: 0 if deployed and pods ready (or already healthy); 1 if helm failed or
#          pods did not become ready (caller decides whether that's fatal).
#------------------------------------------------------------------------------
_deploy_openg2p_release() {
  local chart_name="$1"
  local release_name="$2"
  local chart_src="$OPENG2P_HELM_DIR/$chart_name"
  local chart_work="$DEPLOY_WORK_DIR/$chart_name"

  local status
  status=$(helm status "$release_name" -n "$OPENG2P_NAMESPACE" -o json 2>/dev/null \
    | grep -o '"status":"[a-z-]*"' | head -1 | cut -d'"' -f4)

  # A pending-*/failed release blocks the next upgrade. If its pods are actually healthy,
  # promote the record to "deployed" rather than wiping it (which would re-init Postgres).
  if [[ "$status" == pending-* || "$status" == "failed" ]]; then
    if _openg2p_release_pods_healthy "$release_name"; then
      log_step "Release '$release_name' is '$status' but pods are healthy — promoting to deployed"
      _promote_pending_release "$release_name" && status="deployed"
      log_ok
    fi
  fi

  if [[ -n "$status" && "$status" != "deployed" ]]; then
    log_step "Previous '$release_name' release is '$status' — clearing it"
    _clean_openg2p_release "$release_name"
    log_ok
  fi

  # Idempotent skip: re-running helm re-applies every object and re-fires hook jobs (slow).
  # Skip a healthy deployed release outright; `helm uninstall` forces a real redeploy.
  if [[ "$status" == "deployed" ]] && _openg2p_release_pods_healthy "$release_name"; then
    log_skipped "$release_name already deployed and healthy — skipping (helm uninstall to force)"
    return 0
  fi

  log_step "Copying $release_name chart to working directory"
  rm -rf "$chart_work"
  mkdir -p "$chart_work"
  cp -r "$chart_src/." "$chart_work/"
  log_ok

  log_step "Updating FQDNs in $release_name values"
  apply_domain_to_file "$chart_work/values.yaml" "$GAZELLE_DOMAIN"
  log_ok

  log_step "Fetching $release_name chart dependencies"
  ensure_helm_dependencies "$chart_work"
  log_ok

  # No `--wait`: on large charts helm's rate-limited readiness poll stalls for minutes and
  # can mark the release "failed" even when pods came up. We apply and return, then judge
  # readiness from real pod state via _wait_for_openg2p_release_ready() below. --qps raises
  # the client limit for the apply itself.
  log_step "Deploying $release_name"
  if ! helm upgrade --install \
    --qps "${OPENG2P_HELM_QPS:-50}" \
    --timeout "${startup_timeout:-1200}s" \
    "$release_name" "$chart_work" \
    -n "$OPENG2P_NAMESPACE"; then
    log_warn "helm upgrade $release_name failed"
    return 1
  fi
  log_ok

  # Per-release readiness gate: "really deployed" means the pods are actually Ready,
  # not merely that helm applied the manifests (we deploy without --wait). Returns
  # non-zero on timeout or terminal pod failure so the caller can record/skip it
  # instead of the whole deploy sticking on one module.
  _wait_for_openg2p_release_ready "$release_name" "${startup_timeout:-1200}"
}

#------------------------------------------------------------------------------
# Function : _openg2p_preflight_secrets
# Description: Idempotently stubs secrets a module's chart mounts unconditionally but
#              that Gazelle's split-release layout never creates (upstream assumes one
#              monolithic install). Without them init containers die with
#              CreateContainerConfigError. Placeholder passwords — enough to boot; real
#              cross-module DB access is a follow-up (see g2p-bridge values.yaml).
#   $1 = module name
#------------------------------------------------------------------------------
_openg2p_preflight_secrets() {
  local module="$1"
  case "$module" in
    pbms)
      # PBMS bg-task pods mount the social-registry postgres secret. When SR is disabled
      # it is never created, so stub it. Guarded: if SR is enabled it deploys first (earlier
      # in OPENG2P_MODULES) and creates the real secret, so this is skipped.
      if ! kubectl get secret social-registry-postgresql -n "$OPENG2P_NAMESPACE" >/dev/null 2>&1; then
        log_step "Pre-creating pbms prerequisite secret 'social-registry-postgresql'"
        kubectl create secret generic social-registry-postgresql -n "$OPENG2P_NAMESPACE" \
          --from-literal="postgres-password=placeholder" \
          --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
        log_ok
      fi
      ;;
    g2p-bridge)
      local s
      # secret name : key  (the Keycloak OIDC client secret + cross-module DB user secrets)
      for s in "openg2p-g2p-bridge-openg2p:client_secret" "pbms:pbms-db-user" "registry:registry-db-user"; do
        local name="${s%%:*}" key="${s##*:}"
        if ! kubectl get secret "$name" -n "$OPENG2P_NAMESPACE" >/dev/null 2>&1; then
          log_step "Pre-creating g2p-bridge prerequisite secret '$name'"
          kubectl create secret generic "$name" -n "$OPENG2P_NAMESPACE" \
            --from-literal="$key=placeholder" \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
          log_ok
        fi
      done
      ;;
  esac
}

#------------------------------------------------------------------------------
# Function : _openg2p_postdeploy
# Description: Idempotent per-module fixups that must run AFTER the module's pods are
#              ready (unlike _openg2p_preflight_secrets which runs before). Safe to run
#              on every deploy/redeploy.
#   $1 = module name
#------------------------------------------------------------------------------
_openg2p_postdeploy() {
  local module="$1"
  case "$module" in
    pbms)
      # Required: the pbms-core image does not apply ODOO_PASSWORD to the admin row, so
      # without this fixup a fresh deploy is locked out of the Odoo UI.
      _openg2p_pbms_fix_admin_login
      # Wire up the PBMS->PHEE connector (installs the payment addons). Needs pod
      # network egress. Idempotent — re-running short-circuits already-applied steps.
      _openg2p_pbms_setup_phee
      ;;
  esac
}

#------------------------------------------------------------------------------
# Function : _openg2p_pbms_setup_phee
# Description: Runs the idempotent g2p_payment_phee enablement script. Non-fatal: a
#              failure logs a warning and does not abort the deploy.
#------------------------------------------------------------------------------
_openg2p_pbms_setup_phee() {
  local script="${BASE_DIR}/src/utils/openg2p/setup-pbms-phee.sh"
  [[ -x "$script" || -f "$script" ]] || { log_warn "setup-pbms-phee.sh not found at $script — skipping PHEE setup"; return 0; }
  log_with_level "$INFO" "Enabling g2p_payment_phee connector on PBMS (this runs setup-pbms-phee.sh)"
  if ! bash "$script"; then
    log_warn "g2p_payment_phee setup did not complete — run $script manually"
  fi
}

#------------------------------------------------------------------------------
# Function : _openg2p_pbms_fix_admin_login
# Description: Resets the PBMS Odoo admin user's login/password (via Odoo's ORM, so the
#              hash is valid) to match the 'pbms-odoo' secret — the image bootstrap does
#              not, leaving a fresh install locked out. Idempotent.
#              Creds: login "admin@openg2p.org", password from:
#                kubectl get secret pbms-odoo -n openg2p \
#                  -o jsonpath='{.data.odoo-password}' | base64 -d
#------------------------------------------------------------------------------
_openg2p_pbms_fix_admin_login() {
  local pod pw db="pbmsdb" email="admin@openg2p.org"
  pod=$(kubectl get pods -n "$OPENG2P_NAMESPACE" --no-headers 2>/dev/null \
    | awk '/^pbms-odoo-/ && $3=="Running"{print $1; exit}')
  [[ -z "$pod" ]] && { log_with_verbose_check "$debug" "$DEBUG" "pbms odoo pod not found — skipping admin fixup"; return 0; }

  pw=$(kubectl get secret pbms-odoo -n "$OPENG2P_NAMESPACE" -o jsonpath='{.data.odoo-password}' 2>/dev/null | base64 -d)
  [[ -z "$pw" ]] && { log_warn "pbms-odoo secret has no odoo-password — skipping admin fixup"; return 0; }

  log_step "Aligning PBMS Odoo admin login/password (login: admin or $email)"
  # Run inside the odoo pod via its shell so the password is hashed by Odoo itself.
  # base id 2 = the built-in admin user. Set login=email AND password; commit.
  #
  # The login/password/db are passed as POSITIONAL ARGS to the pod's `bash -lc` (the
  # trailing "$db" "$email" "$pw" become $0/$1/$2 inside), exported to the environment,
  # and read from os.environ in the Python — they are NOT interpolated into the shell
  # string or a Python '...' literal. `kubectl exec` has no --env flag, so args+export
  # is the injection-safe path. The password comes from a k8s secret and can contain
  # ', $, backticks, or newlines; interpolating it would break the Python literal
  # (silent lockout) or shell-expand it. The Python heredoc is single-quoted ('PYEOF')
  # so nothing expands inside it either.
  kubectl exec -i -n "$OPENG2P_NAMESPACE" "$pod" -- \
    bash -lc '
      export ODOO_DB="$1" ODOO_LOGIN="$2" ODOO_PW="$3"
      odoo shell -c /etc/odoo/odoo.conf -d "$ODOO_DB" --no-http 2>/dev/null | grep -q PBMS_ADMIN_OK
    ' _ "$db" "$email" "$pw" <<'PYEOF' >/dev/null 2>&1
import os
u = env['res.users'].browse(2)
u.write({'login': os.environ['ODOO_LOGIN'], 'password': os.environ['ODOO_PW']})
env.cr.commit()
print('PBMS_ADMIN_OK')
PYEOF
  if [[ $? -eq 0 ]]; then
    log_ok
  else
    log_warn "PBMS admin login fixup did not complete — set it manually (odoo shell on the pbms-odoo pod)"
  fi
}

#------------------------------------------------------------------------------
# Function : _openg2p_module_enabled
# Description: Returns "true"/"false" for a module from its OPENG2P_*_ENABLED config.
#------------------------------------------------------------------------------
_openg2p_module_enabled() {
  local module="$1"
  local val
  case "$module" in
    social-registry) val="${OPENG2P_SOCIAL_REGISTRY_ENABLED:-true}" ;;
    pbms)            val="${OPENG2P_PBMS_ENABLED:-true}" ;;
    spar)            val="${OPENG2P_SPAR_ENABLED:-true}" ;;
    g2p-bridge)      val="${OPENG2P_G2P_BRIDGE_ENABLED:-true}" ;;
    *)               val="false" ;;
  esac
  echo "$val" | tr '[:upper:]' '[:lower:]'
}

#------------------------------------------------------------------------------
# Function : _openg2p_commons_needed
# Description: The commons release (Postgres + postgres-init + Keycloak) is the
#   shared DB/SSO foundation for the modules that connect to it: social-registry,
#   spar and g2p-bridge. PBMS is self-contained — it runs its own odoo Postgres
#   and bg-task DBs and logs in via local Odoo auth — so a PBMS-only deploy needs
#   no commons workload at all. Returns 0 (true) when any commons consumer is enabled.
#
#   Skipping commons for a PBMS-only run also keeps that path ARM-clean: the only
#   custom amd64-only OpenG2P images (keycloak -g2p1, keycloak-init, postgres-init)
#   live in commons, so not deploying it removes them.
#------------------------------------------------------------------------------
_openg2p_commons_needed() {
  local m
  for m in social-registry spar g2p-bridge; do
    [[ "$(_openg2p_module_enabled "$m")" == "true" ]] && return 0
  done
  return 1
}

#------------------------------------------------------------------------------
# Function : _clean_openg2p_release
# Description: Uninstalls one helm release and clears any orphaned objects it left
#              (failed first-revision installs leave objects Helm never recorded).
#              Deletes synchronously so a following reinstall never races stragglers.
#   $1 = helm release name (also the object name prefix)
#------------------------------------------------------------------------------
_clean_openg2p_release() {
  local release_name="$1"
  helm uninstall "$release_name" -n "$OPENG2P_NAMESPACE" --wait --timeout 300s 2>/dev/null || true

  # Workloads first (release their volumes), then everything else, PVCs last. STS PVCs
  # are retained by k8s on delete — remove them explicitly or postgres reuses stale data.
  local kind
  for kind in deployment statefulset replicaset job; do
    kubectl get "$kind" -n "$OPENG2P_NAMESPACE" --no-headers 2>/dev/null \
      | awk -v p="^${release_name}-" '$1 ~ p || $1 == "'"$release_name"'" {print $1}' \
      | xargs -r kubectl delete "$kind" -n "$OPENG2P_NAMESPACE" --wait=true --timeout=120s 2>/dev/null >/dev/null || true
  done

  kubectl get pods -n "$OPENG2P_NAMESPACE" --no-headers 2>/dev/null \
    | awk -v p="^${release_name}-" '$1 ~ p {print $1}' \
    | xargs -r kubectl delete pod -n "$OPENG2P_NAMESPACE" --force --grace-period=0 2>/dev/null >/dev/null || true

  for kind in service secret configmap networkpolicy poddisruptionbudget ingress \
              serviceaccount virtualservice gateway servicemonitor flow output; do
    kubectl get "$kind" -n "$OPENG2P_NAMESPACE" --no-headers 2>/dev/null \
      | awk -v p="^${release_name}-" '$1 ~ p || $1 == "'"$release_name"'" {print $1}' \
      | xargs -r kubectl delete "$kind" -n "$OPENG2P_NAMESPACE" --wait=true --timeout=120s 2>/dev/null >/dev/null || true
  done

  # PVCs last, matched as a substring: STS PVCs are named "<template>-<release>-<sts>-<n>"
  # so the release name is not at the start — a prefix match would miss them.
  kubectl get pvc -n "$OPENG2P_NAMESPACE" --no-headers 2>/dev/null \
    | awk -v r="${release_name}-" '$1 ~ ("^" r) || index($1, "-" r) > 0 {print $1}' \
    | xargs -r kubectl delete pvc -n "$OPENG2P_NAMESPACE" --wait=true --timeout=120s 2>/dev/null >/dev/null || true
}

#------------------------------------------------------------------------------
# Function : _openg2p_release_pods
# Description: Echoes the pod lines belonging to a release (by "<release>-" name prefix),
#              dropping leftover Failed pods whose owning Job has already succeeded — a
#              first-attempt-failed-then-retried Job pod is not a deployment failure but
#              would otherwise keep the readiness wait from ever settling.
#   $1 = release name (pod name prefix)
#------------------------------------------------------------------------------
_openg2p_release_pods() {
  local release_name="$1"
  # Names of Jobs with ≥1 success (jsonpath, not column-guessing — layout varies by
  # kubectl version). Their failed retry pods are stale artifacts to drop below.
  local succeeded_jobs
  succeeded_jobs=$(kubectl get jobs -n "$OPENG2P_NAMESPACE" \
    -o jsonpath='{range .items[?(@.status.succeeded>=1)]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

  kubectl get pods -n "$OPENG2P_NAMESPACE" --no-headers 2>/dev/null \
    | awk -v p="^${release_name}-" -v sj="$succeeded_jobs" '
        BEGIN { n=split(sj, J, "\n") }
        $1 !~ p { next }
        # Keep pods that are NOT in a failed/error-ish phase regardless of Job status.
        $3 != "Error" && $3 != "Failed" && $3 !~ /BackOff|CreateContainer|InvalidImage/ { print; next }
        # For failed-ish pods, drop them only if they belong to an already-succeeded Job.
        {
          for (i=1; i<=n; i++) {
            if (J[i] != "" && index($1, J[i] "-") == 1) next   # stale replica of a done Job → skip
          }
          print   # genuinely-failed pod of a not-yet-succeeded workload → keep
        }
      '
}

#------------------------------------------------------------------------------
# Function : _openg2p_release_pods_healthy
# Description: Returns 0 if the release has ≥1 Running+Ready workload pod AND no
#              not-ready pods (ignoring Completed/Succeeded jobs). Point-in-time check.
#              The ≥1-Running requirement matters: a release whose only pod is a
#              completed hook/init Job (workload pods not scheduled yet) must NOT be
#              called healthy just because "nothing is failing" — there's no serving
#              pod. Without it, the readiness gate could settle on a job-only release.
#   $1 = release name (pod name prefix)
#------------------------------------------------------------------------------
_openg2p_release_pods_healthy() {
  local release_name="$1"
  local pods bad ready
  pods=$(_openg2p_release_pods "$release_name")
  [[ -z "$pods" ]] && return 1
  # Any pod not Running/Completed, or Running but not all containers Ready → unhealthy
  bad=$(echo "$pods" | awk '
    $3=="Completed" || $3=="Succeeded" {next}
    $3!="Running" {print; next}
    {split($2,a,"/"); if (a[1]!=a[2] || a[1]==0) print}')
  [[ -n "$bad" ]] && return 1
  # Require at least one Running pod with all containers Ready — a set of only
  # Completed/Succeeded job pods is not a healthy *workload*.
  ready=$(echo "$pods" | awk '
    $3=="Running" {split($2,a,"/"); if (a[1]==a[2] && a[1]>0) print}')
  [[ -n "$ready" ]]
}

#------------------------------------------------------------------------------
# Function : _openg2p_release_pods_terminal
# Description: Echoes pods in a durably-terminal state that will not self-heal:
#              CreateContainer*/InvalidImageName (wrong Secret/ConfigMap/image) and
#              chronic CrashLoopBackOff (restarts >= threshold). Transient states
#              (ImagePullBackOff from pull-QPS, a single early crash) are NOT terminal —
#              they clear on their own. The caller only acts after a persistence window.
#   $1 = release name (pod name prefix)
#------------------------------------------------------------------------------
_openg2p_release_pods_terminal() {
  local release_name="$1"
  # restartCount at/above which a CrashLoopBackOff is considered chronic (not first-boot)
  local crash_restart_threshold="${OPENG2P_CRASH_RESTART_THRESHOLD:-5}"
  _openg2p_release_pods "$release_name" | awk -v thr="$crash_restart_threshold" '
    $3=="Completed" || $3=="Succeeded" {next}
    # Config/image-spec errors never self-heal → durably terminal regardless of restarts.
    $3 ~ /CreateContainerConfigError|CreateContainerError|InvalidImageName/ {print; next}
    $3 ~ /^Init:.*(CreateContainerConfigError|CreateContainerError|InvalidImageName)/ {print; next}
    # CrashLoopBackOff only counts as terminal once restarts are chronic ($4 = RESTARTS,
    # which may be like "7 (2m ago)" so take the leading integer).
    $3 ~ /CrashLoopBackOff/ || $3 ~ /^Init:.*CrashLoopBackOff/ {
      r=$4; sub(/[^0-9].*/,"",r); if (r=="" ) r=0;
      if (r+0 >= thr) print;
      next
    }
  '
}

#------------------------------------------------------------------------------
# Function : _wait_for_openg2p_release_ready
# Description: Per-release readiness gate (polls only one release's pods by name prefix,
#              so one broken module never blocks a healthy one). Returns 0 once the pods
#              stay Ready for N consecutive polls; 1 on timeout or a durable failure that
#              persists past the grace window. Caller warns and continues either way.
#   $1 = release name (pod name prefix)
#   $2 = timeout seconds (default: startup_timeout, else 600)
# Env tunables: OPENG2P_TERMINAL_GRACE_SECS (180), OPENG2P_CRASH_RESTART_THRESHOLD (5).
#------------------------------------------------------------------------------
_wait_for_openg2p_release_ready() {
  local release_name="$1"
  local timeout="${2:-${startup_timeout:-600}}"
  local interval=10
  local required_stable=3      # consecutive all-ready polls before we trust it
  # How long a durable-terminal condition must persist before we give up. Long on purpose:
  # a missing Secret is often created seconds later by a sibling init Job.
  local terminal_grace_secs="${OPENG2P_TERMINAL_GRACE_SECS:-180}"
  local terminal_strikes_needed=$(( terminal_grace_secs / interval ))
  (( terminal_strikes_needed < 1 )) && terminal_strikes_needed=1
  local elapsed=0 stable=0 terminal_strikes=0

  log_step "Waiting for $release_name pods to be ready"

  while true; do
    if [[ "$elapsed" -ge "$timeout" ]]; then
      log_warn "$release_name pods did not become ready within ${timeout}s — continuing"
      _openg2p_release_pods "$release_name" | awk '
        $3=="Completed"||$3=="Succeeded"{next}
        {split($2,a,"/"); if(a[1]!=a[2]||a[1]==0) print "      ⏳ "$1" ("$3")"}'
      return 1
    fi

    # No pods yet? The release may still be creating them — keep waiting (within timeout).
    if [[ -z "$(_openg2p_release_pods "$release_name")" ]]; then
      stable=0; terminal_strikes=0
      sleep "$interval"; elapsed=$((elapsed + interval)); continue
    fi

    # Durable failure persisting for terminal_grace_secs → give up on this release. The
    # strike counter resets the instant the condition clears, so transient backoffs don't trip it.
    if [[ -n "$(_openg2p_release_pods_terminal "$release_name")" ]]; then
      terminal_strikes=$((terminal_strikes + 1))
      stable=0
      log_with_verbose_check "$debug" "$DEBUG" \
        "$release_name has durably-failing pod(s) — strike $terminal_strikes/$terminal_strikes_needed (${terminal_grace_secs}s grace)"
      if [[ "$terminal_strikes" -ge "$terminal_strikes_needed" ]]; then
        log_warn "$release_name has pod(s) stuck in a durable failure state for >${terminal_grace_secs}s — continuing without it"
        _openg2p_release_pods_terminal "$release_name" | awk '{print "      ✗ "$1" ("$3", restarts="$4")"}'
        return 1
      fi
      sleep "$interval"; elapsed=$((elapsed + interval)); continue
    fi
    terminal_strikes=0

    if _openg2p_release_pods_healthy "$release_name"; then
      stable=$((stable + 1))
      log_with_verbose_check "$debug" "$DEBUG" "$release_name all pods ready — stable $stable/$required_stable"
      [[ "$stable" -ge "$required_stable" ]] && { log_ok; return 0; }
    else
      stable=0
      log_with_verbose_check "$debug" "$DEBUG" "$release_name pods still starting — waiting ${interval}s..."
    fi

    sleep "$interval"; elapsed=$((elapsed + interval))
  done
}

#------------------------------------------------------------------------------
# Function : _promote_pending_release
# Description: Rewrites a stuck pending-install/pending-upgrade helm release record to
#              "deployed" (helm --wait was interrupted before it returned). Edits the
#              release secret's embedded status JSON + the status label. No data loss.
#   $1 = release name
#------------------------------------------------------------------------------
_promote_pending_release() {
  local release_name="$1"
  # Newest release secret for this release (highest revision). Helm names these
  # `sh.helm.release.v1.<name>.v<N>`; we must sort by the integer <N>, NOT by a
  # dot-field index — field 5 is the (constant) release name and field 6 is `v<N>`
  # whose leading `v` makes `sort -n` read it as 0 (so every revision ties). Split on
  # the literal `.v` separator and sort on the trailing number.
  local secret
  secret=$(kubectl get secret -n "$OPENG2P_NAMESPACE" \
    -l "owner=helm,name=${release_name}" --no-headers 2>/dev/null \
    | awk '{print $1}' \
    | awk -F'.v' '{print $NF"\t"$0}' | sort -n -k1,1 | tail -1 | cut -f2-)
  [[ -z "$secret" ]] && return 1

  # release data = base64(base64(gzip(json))); flip info.status to deployed, re-encode
  local new
  new=$(kubectl get secret -n "$OPENG2P_NAMESPACE" "$secret" -o jsonpath='{.data.release}' 2>/dev/null \
    | base64 -d | base64 -d | gunzip 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); d['info']['status']='deployed'; sys.stdout.write(json.dumps(d))" 2>/dev/null \
    | gzip | base64 -w0 | base64 -w0)
  [[ -z "$new" ]] && return 1

  kubectl patch secret -n "$OPENG2P_NAMESPACE" "$secret" --type=merge \
    -p "{\"data\":{\"release\":\"$new\"}}" >/dev/null 2>&1 || return 1
  kubectl label secret -n "$OPENG2P_NAMESPACE" "$secret" status=deployed --overwrite >/dev/null 2>&1
}

#------------------------------------------------------------------------------
# Function : clean_openg2p
# Description: Removes all OpenG2P resources — modules first, then commons,
#              then drops the namespace.
#------------------------------------------------------------------------------
clean_openg2p() {
  log_step "Removing OpenG2P"
  local module
  for module in "${OPENG2P_MODULES[@]}"; do
    helm uninstall "$module" -n "$OPENG2P_NAMESPACE" --wait 2>/dev/null || true
  done
  helm uninstall openg2p-commons -n "$OPENG2P_NAMESPACE" --wait 2>/dev/null || true
  delete_resources_in_namespace_matching_pattern "$OPENG2P_NAMESPACE"
  log_ok
}
